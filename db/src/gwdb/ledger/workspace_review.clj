(ns gwdb.ledger.workspace-review
  (:require [tahto.core :as l]
            [postgres.core :as pg]
            [gwdb.ledger.account :as account]
            [gwdb.ledger.admission :as admission]
            [gwdb.ledger.block :as block]
            [gwdb.ledger.cell :as cell]
            [gwdb.ledger.crypto :as crypto]
            [gwdb.ledger.op :as op]
            [gwdb.ledger.scoped-ref :as scoped-ref]
            [gwdb.ledger.state :as state]
            [gwdb.ledger.transaction :as transaction]
            [gwdb.ledger.value :as value]
            [gwdb.ledger.workspace :as workspace]
            [gwdb.ledger.workspace-admission :as workspace-admission]
            [gwdb.ledger.workspace-proposal :as workspace-proposal]))

(l/script :postgres
  {:require [[postgres.core :as pg]
             [gwdb.ledger.account :as account]
             [gwdb.ledger.admission :as admission]
             [gwdb.ledger.block :as block]
             [gwdb.ledger.cell :as cell]
             [gwdb.ledger.crypto :as crypto]
             [gwdb.ledger.op :as op]
             [gwdb.ledger.scoped-ref :as scoped-ref]
             [gwdb.ledger.state :as state]
             [gwdb.ledger.transaction :as transaction]
             [gwdb.ledger.value :as value]
             [gwdb.ledger.workspace :as workspace]
             [gwdb.ledger.workspace-admission :as workspace-admission]
             [gwdb.ledger.workspace-proposal :as workspace-proposal]]
   :config {:dbname "gw-ledger-test"}
   :import [["pgcrypto"] ["pgsodium"]]
   :static {:application ["gw"]
            :all {:schema ["gw_ledger"]}}})

(deftype.pg WorkspaceReview
  "Rebuildable projection of one canonical reviewer decision."
  {:added "0.14"}
  [:review-root       {:type :bytea :primary true}
   :workspace-id-root {:type :bytea :required true}
   :candidate-root    {:type :bytea :required true}
   :reviewer-root     {:type :bytea :required true}
   :decision          {:type :text :required true}
   :recorded-at       {:type :bigint :required true}])

(defn.pg ^{:- [:boolean]}
  review-decision-valid
  {:added "0.14"}
  [:text i-decision]
  (return
   (or (== i-decision "approve")
       (== i-decision "reject")
       (== i-decision "withdraw"))))

(defn.pg ^{:- [:text]}
  review-id
  {:added "0.14"}
  [:bytea i-candidate-root :bytea i-reviewer-root]
  (return
   (|| "review/"
       (pg/encode i-candidate-root "hex") "/"
       (pg/encode i-reviewer-root "hex"))))

(defn.pg ^{:- [:text]}
  review-ref-name
  {:added "0.14"}
  [:bytea i-candidate-root :bytea i-reviewer-root]
  (return (-/review-id i-candidate-root i-reviewer-root)))

(defn.pg ^{:- [:text]}
  review-subject-id
  {:added "0.14"}
  [:bytea i-candidate-root]
  (return
   (workspace-proposal/proposal-name i-candidate-root)))

(defn.pg ^{:- [:bytea]}
  review-recorded-evidence-value
  "Constructs constrained signed reviewer evidence."
  {:added "0.14"}
  [:bytea i-reviewer-root :bigint i-recorded-at]
  (let [(:bytea v-empty-map)
        (value/put-map (pg/jsonb-build-array))
        (:bytea v-record)
        (workspace/record-start "ledger/evidence")
        (:bytea v-version)
        (workspace/record-assoc
         v-record "record/version" (value/put-integer-number 1))
        (:bytea v-extensions)
        (workspace/record-assoc
         v-version "record/extensions" v-empty-map)
        (:bytea v-signer)
        (workspace/record-assoc
         v-extensions "ledger/signer" i-reviewer-root)
        (:bytea v-transaction)
        (workspace/record-assoc
         v-signer "ledger/transaction-root" (value/put-nil))
        (:bytea v-timestamp)
        (workspace/record-assoc
         v-transaction "ledger/timestamp"
         (value/put-integer-number i-recorded-at))
        (:bytea v-head)
        (workspace/record-assoc
         v-timestamp "ledger/previous-head-root" (value/put-nil))
        (:bytea v-contract)
        (workspace/record-assoc
         v-head "ledger/contract-root" (value/put-nil))
        (:bytea v-template)
        (workspace/record-assoc
         v-contract "ledger/template-root" (value/put-nil))]
    (return
     (workspace/record-assoc
      v-template "ledger/global-state-root" (value/put-nil)))))

(defn.pg ^{:- [:bytea]}
  workspace-review-value
  "Constructs one canonical immutable decision for an exact candidate."
  {:added "0.14"}
  [:bytea i-candidate-root
   :bytea i-reviewer-root
   :text i-decision
   :bigint i-recorded-at]
  (let [(:bytea v-empty-map)
        (value/put-map (pg/jsonb-build-array))
        (:bytea v-empty-vector)
        (value/put-vector (pg/jsonb-build-array))
        (:bytea v-record)
        (workspace/record-start "review/decision")
        (:bytea v-version)
        (workspace/record-assoc
         v-record "record/version" (value/put-integer-number 1))
        (:bytea v-extensions)
        (workspace/record-assoc
         v-version "record/extensions" v-empty-map)
        (:bytea v-id)
        (workspace/record-assoc
         v-extensions "review/id"
         (value/put-string
          (-/review-id i-candidate-root i-reviewer-root)))
        (:bytea v-subject-id)
        (workspace/record-assoc
         v-id "review/subject-id"
         (value/put-string (-/review-subject-id i-candidate-root)))
        (:bytea v-subject-root)
        (workspace/record-assoc
         v-subject-id "review/subject-root" i-candidate-root)
        (:bytea v-decision)
        (workspace/record-assoc
         v-subject-root "review/decision"
         (value/put-keyword i-decision))
        (:bytea v-evidence-roots)
        (workspace/record-assoc
         v-decision "review/evidence-roots" v-empty-vector)
        (:bytea v-process-id)
        (workspace/record-assoc
         v-evidence-roots "review/process-run-id" (value/put-nil))
        (:bytea v-process-root)
        (workspace/record-assoc
         v-process-id "review/process-run-root" (value/put-nil))
        (:bytea v-evidence)
        (workspace/record-assoc
         v-process-root "review/recorded-evidence"
         (-/review-recorded-evidence-value
          i-reviewer-root i-recorded-at))]
    (return
     (workspace/record-assoc
      v-evidence "review/metadata" v-empty-map))))

(defn.pg workspace-review-row
  {:added "0.14"}
  [:bytea i-review-root]
  (return
   (pg/t:get -/WorkspaceReview
             {:where {:review-root i-review-root}})))

(defn.pg ^{:- [:text]}
  review-decision-text
  {:added "0.14"}
  [:bytea i-decision-root]
  (return
   (pg/case (== i-decision-root
                (workspace/keyword-root "approve"))
            "approve"
            (== i-decision-root
                (workspace/keyword-root "reject"))
            "reject"
            (== i-decision-root
                (workspace/keyword-root "withdraw"))
            "withdraw"
            :else nil)))

(defn.pg ^{:- [:text]}
  workspace-review-error
  "Returns the first canonical review validation failure, or SQL null."
  {:added "0.14"}
  [:bytea i-review-root]
  (cond (not
         (workspace/record-kind i-review-root "review/decision"))
        (return "workspace/invalid-review-record")

        (not (workspace/record-version-one i-review-root))
        (return "workspace/unsupported-review-version")

        :else
        (let [(:bytea v-candidate-root)
              (workspace/field i-review-root "review/subject-root")
              o-candidate
              (workspace/workspace-commit-row v-candidate-root)
              (:bytea v-id-root)
              (workspace/field i-review-root "review/id")
              (:bytea v-subject-id-root)
              (workspace/field i-review-root "review/subject-id")
              (:bytea v-decision-root)
              (workspace/field i-review-root "review/decision")
              (:text v-decision)
              (-/review-decision-text v-decision-root)
              (:bytea v-evidence-roots)
              (workspace/field i-review-root "review/evidence-roots")
              o-evidence-roots (cell/cell-by-hash v-evidence-roots)
              (:bytea v-process-id)
              (workspace/optional-field
               i-review-root "review/process-run-id")
              (:bytea v-process-root)
              (workspace/optional-field
               i-review-root "review/process-run-root")
              (:bytea v-recorded-evidence)
              (workspace/field
               i-review-root "review/recorded-evidence")
              (:bytea v-reviewer-root)
              (workspace/field v-recorded-evidence "ledger/signer")
              (:bytea v-recorded-at-root)
              (workspace/field v-recorded-evidence "ledger/timestamp")
              o-recorded-at (cell/cell-by-hash v-recorded-at-root)
              (:bytea v-metadata-root)
              (workspace/field i-review-root "review/metadata")
              (:bytea v-extensions-root)
              (workspace/field i-review-root "record/extensions")
              (:bytea v-empty-map)
              (value/put-map (pg/jsonb-build-array))]
          (cond [o-candidate :is-null]
                (return "workspace/review-candidate-not-found")

                (not
                 (workspace/workspace-commit-valid v-candidate-root))
                (return "workspace/invalid-review-candidate")

                (or [(cell/cell-by-hash v-id-root) :is-null]
                    (not (== (cell/cell-type-tag v-id-root) 5)))
                (return "workspace/invalid-review-id")

                (or [(cell/cell-by-hash v-subject-id-root) :is-null]
                    (not (== (cell/cell-type-tag v-subject-id-root) 5)))
                (return "workspace/invalid-review-subject-id")

                [v-decision :is-null]
                (return "workspace/invalid-review-decision")

                (or [o-evidence-roots :is-null]
                    (not
                     (== (:smallint (:->> o-evidence-roots "type_tag")) 10))
                    (not
                     (== (cell/cell-ref-count
                          v-evidence-roots "element") 0)))
                (return "workspace/review-evidence-roots-not-supported")

                [v-process-id :is-not-null]
                (return "workspace/review-process-run-not-supported")

                [v-process-root :is-not-null]
                (return "workspace/review-process-run-not-supported")

                (not
                 (workspace/record-kind
                  v-recorded-evidence "ledger/evidence"))
                (return "workspace/invalid-review-recorded-evidence")

                (not
                 (workspace/record-version-one v-recorded-evidence))
                (return "workspace/unsupported-review-evidence-version")

                [(cell/cell-by-hash v-reviewer-root) :is-null]
                (return "workspace/missing-reviewer")

                (or [o-recorded-at :is-null]
                    (not
                     (== (:smallint (:->> o-recorded-at "type_tag")) 2)))
                (return "workspace/invalid-review-recorded-at")

                [ (workspace/optional-field
                    v-recorded-evidence "ledger/transaction-root")
                  :is-not-null]
                (return "workspace/review-transaction-evidence-not-supported")

                [ (workspace/optional-field
                    v-recorded-evidence "ledger/previous-head-root")
                  :is-not-null]
                (return "workspace/review-head-evidence-not-supported")

                [ (workspace/optional-field
                    v-recorded-evidence "ledger/contract-root")
                  :is-not-null]
                (return "workspace/review-contract-evidence-not-supported")

                [ (workspace/optional-field
                    v-recorded-evidence "ledger/template-root")
                  :is-not-null]
                (return "workspace/review-template-evidence-not-supported")

                [ (workspace/optional-field
                    v-recorded-evidence "ledger/global-state-root")
                  :is-not-null]
                (return "workspace/review-state-evidence-not-supported")

                (not (== v-metadata-root v-empty-map))
                (return "workspace/review-metadata-not-supported")

                (not (== v-extensions-root v-empty-map))
                (return "workspace/review-extensions-not-supported")

                :else
                (let [(:bigint v-recorded-at)
                      (value/integer-bigint v-recorded-at-root)
                      (:bytea v-reconstructed)
                      (-/workspace-review-value
                       v-candidate-root v-reviewer-root
                       v-decision v-recorded-at)]
                  (cond (< v-recorded-at 0)
                        (return "workspace/invalid-review-recorded-at")

                        (not (== v-id-root
                                 (value/put-string
                                  (-/review-id
                                   v-candidate-root v-reviewer-root))))
                        (return "workspace/review-id-not-derived")

                        (not (== v-subject-id-root
                                 (value/put-string
                                  (-/review-subject-id
                                   v-candidate-root))))
                        (return "workspace/review-subject-id-not-proposal")

                        (not (== v-recorded-evidence
                                 (-/review-recorded-evidence-value
                                  v-reviewer-root v-recorded-at)))
                        (return "workspace/noncanonical-review-evidence")

                        (not (== i-review-root v-reconstructed))
                        (return "workspace/noncanonical-review")

                        :else
                        (return nil)))))))

(defn.pg ^{:- [:boolean]}
  workspace-review-valid
  "Verifies one projected review against its canonical immutable value."
  {:added "0.14"}
  [:bytea i-review-root]
  (let [o-row (-/workspace-review-row i-review-root)]
    (when [o-row :is-null]
      (return false))
    (let [(:bytea v-candidate-root)
          (:bytea (:->> o-row "candidate_root"))
          (:bytea v-reviewer-root)
          (:bytea (:->> o-row "reviewer_root"))
          (:text v-decision)
          (:text (:->> o-row "decision"))
          (:bigint v-recorded-at)
          (:bigint (:->> o-row "recorded_at"))]
      (return
       (and [(-/workspace-review-error i-review-root) :is-null]
            (== (:bytea (:->> o-row "workspace_id_root"))
                (:bytea
                 (:->>
                  (workspace/workspace-commit-row v-candidate-root)
                  "workspace_id_root")))
            (== i-review-root
                (-/workspace-review-value
                 v-candidate-root v-reviewer-root
                 v-decision v-recorded-at)))))))

(defn.pg ^{:- [:bytea]}
  workspace-review-import
  "Validates and projects one canonical review idempotently."
  {:added "0.14"}
  [:bytea i-review-root]
  (let [o-existing (-/workspace-review-row i-review-root)]
    (when [o-existing :is-not-null]
      (pg/assert (-/workspace-review-valid i-review-root)
                 [:ledger/workspace-review-projection-conflict])
      (return i-review-root))
    (let [(:text v-error) (-/workspace-review-error i-review-root)
          _ (pg/assert [v-error :is-null]
                       [:ledger/invalid-workspace-review v-error])
          (:bytea v-candidate-root)
          (workspace/field i-review-root "review/subject-root")
          o-candidate (workspace/workspace-commit-row v-candidate-root)
          (:bytea v-evidence-root)
          (workspace/field i-review-root "review/recorded-evidence")
          (:bytea v-reviewer-root)
          (workspace/field v-evidence-root "ledger/signer")
          (:bigint v-recorded-at)
          (value/integer-bigint
           (workspace/field v-evidence-root "ledger/timestamp"))
          (:text v-decision)
          (-/review-decision-text
           (workspace/field i-review-root "review/decision"))
          o-insert
          (pg/t:insert
           -/WorkspaceReview
           {:review-root i-review-root
            :workspace-id-root
            (:bytea (:->> o-candidate "workspace_id_root"))
            :candidate-root v-candidate-root
            :reviewer-root v-reviewer-root
            :decision v-decision
            :recorded-at v-recorded-at})]
      (return i-review-root))))

(defn.pg ^{:- [:bytea]}
  workspace-review-put
  "Constructs and projects one canonical review decision."
  {:added "0.14"}
  [:bytea i-candidate-root
   :bytea i-reviewer-root
   :text i-decision
   :bigint i-recorded-at]
  (let [_ (pg/assert (-/review-decision-valid i-decision)
                     [:ledger/invalid-review-decision])
        _ (pg/assert (>= i-recorded-at 0)
                     [:ledger/invalid-review-recorded-at])
        (:bytea v-root)
        (-/workspace-review-value
         i-candidate-root i-reviewer-root
         i-decision i-recorded-at)]
    (return (-/workspace-review-import v-root))))

(defn.pg ^{:- [:text]}
  review-scope
  {:added "0.14"}
  [:bytea i-workspace-id-root]
  (return
   (workspace-admission/personal-scope i-workspace-id-root)))

(defn.pg ^{:- [:boolean]}
  proposal-published
  {:added "0.14"}
  [:bytea i-workspace-id-root :bytea i-candidate-root]
  (let [o-row
        (scoped-ref/scoped-ref-row
         (-/review-scope i-workspace-id-root)
         (workspace-proposal/proposal-name i-candidate-root))]
    (return
     (and [o-row :is-not-null]
          (== (:bytea (:->> o-row "root")) i-candidate-root)))))

(defn.pg ^{:- [:text]}
  review-transition-error
  "Returns the first proposal, review or CAS-shape failure, or SQL null."
  {:added "0.14"}
  [:bytea i-workspace-id-root
   :bytea i-candidate-root
   :bytea i-reviewer-root
   :bytea i-expected-review-root
   :text i-decision
   :bigint i-recorded-at]
  (let [o-candidate
        (workspace/workspace-commit-row i-candidate-root)
        o-expected
        (pg/case [i-expected-review-root :is-null]
                 nil
                 :else
                 (-/workspace-review-row i-expected-review-root))]
    (cond [(cell/cell-by-hash i-workspace-id-root) :is-null]
          (return "workspace/invalid-workspace-id")

          [o-candidate :is-null]
          (return "workspace/review-candidate-not-found")

          (not (workspace/workspace-commit-valid i-candidate-root))
          (return "workspace/invalid-review-candidate")

          (not
           (== i-workspace-id-root
               (:bytea (:->> o-candidate "workspace_id_root"))))
          (return "workspace/review-candidate-workspace-mismatch")

          (not (-/proposal-published
                i-workspace-id-root i-candidate-root))
          (return "workspace/review-proposal-not-published")

          (not (-/review-decision-valid i-decision))
          (return "workspace/invalid-review-decision")

          (< i-recorded-at 0)
          (return "workspace/invalid-review-recorded-at")

          (not
           (scoped-ref/ref-part-valid
            (-/review-scope i-workspace-id-root)))
          (return "workspace/invalid-review-ref-scope")

          (not
           (scoped-ref/ref-part-valid
            (-/review-ref-name i-candidate-root i-reviewer-root)))
          (return "workspace/invalid-review-ref-name")

          (and [i-expected-review-root :is-not-null]
               [o-expected :is-null])
          (return "workspace/expected-review-not-found")

          (and [i-expected-review-root :is-not-null]
               (not
                (-/workspace-review-valid i-expected-review-root)))
          (return "workspace/invalid-expected-review")

          (and [i-expected-review-root :is-not-null]
               (not
                (== i-workspace-id-root
                    (:bytea (:->> o-expected "workspace_id_root")))))
          (return "workspace/expected-review-workspace-mismatch")

          (and [i-expected-review-root :is-not-null]
               (not
                (== i-candidate-root
                    (:bytea (:->> o-expected "candidate_root")))))
          (return "workspace/expected-review-candidate-mismatch")

          (and [i-expected-review-root :is-not-null]
               (not
                (== i-reviewer-root
                    (:bytea (:->> o-expected "reviewer_root")))))
          (return "workspace/expected-review-reviewer-mismatch")

          :else
          (return nil))))

(defn.pg ^{:- [:bytea]}
  workspace-review-intent-value
  "Constructs the exact CAS intent for one reviewer/candidate ref."
  {:added "0.14"}
  [:bytea i-workspace-id-root
   :bytea i-candidate-root
   :bytea i-reviewer-root
   :bytea i-expected-review-root
   :bytea i-desired-review-root]
  (let [(:text v-scope) (-/review-scope i-workspace-id-root)
        (:text v-name)
        (-/review-ref-name i-candidate-root i-reviewer-root)
        (:bytea v-empty-map)
        (value/put-map (pg/jsonb-build-array))
        (:bytea v-record)
        (workspace/record-start "workspace/ref-update-intent")
        (:bytea v-version)
        (workspace/record-assoc
         v-record "record/version" (value/put-integer-number 1))
        (:bytea v-extensions)
        (workspace/record-assoc
         v-version "record/extensions" v-empty-map)
        (:bytea v-workspace)
        (workspace/record-assoc
         v-extensions "workspace/id" i-workspace-id-root)
        (:bytea v-scope-record)
        (workspace/record-assoc
         v-workspace "ref/scope" (value/put-string v-scope))
        (:bytea v-name-record)
        (workspace/record-assoc
         v-scope-record "ref/name" (value/put-string v-name))
        (:bytea v-expected)
        (workspace/record-assoc
         v-name-record "ref/expected-root"
         (workspace/optional-root i-expected-review-root))
        (:bytea v-desired)
        (workspace/record-assoc
         v-expected "ref/desired-root" i-desired-review-root)
        (:bytea v-authority)
        (workspace/record-assoc
         v-desired "ref/authorization-root" i-reviewer-root)
        (:bytea v-policy)
        (workspace/record-assoc
         v-authority "ref/policy"
         (value/put-keyword "review-decision-v1"))]
    (return
     (workspace/record-assoc
      v-policy "ref/metadata" v-empty-map))))

(defn.pg ^{:- [:jsonb]}
  workspace-review-signing-request
  "Returns standard transaction bytes for one exact review update."
  {:added "0.14"}
  [:text i-network
   :bytea i-public-key
   :bytea i-workspace-id-root
   :bytea i-candidate-root
   :bytea i-expected-review-root
   :text i-decision
   :bigint i-recorded-at
   :bigint i-cost-limit]
  (let [o-head (block/head-get i-network)
        _ (pg/assert [o-head :is-not-null] [:ledger/network-missing])
        _ (pg/assert (>= i-cost-limit 1) [:ledger/invalid-cost-limit])
        (:bytea v-state-root) (:bytea (:->> o-head "state_root"))
        (:bytea v-address-root)
        (admission/admission-address-root i-public-key)
        (:bytea v-account-root)
        (state/state-account-root v-state-root v-address-root)
        _ (pg/assert [v-account-root :is-not-null]
                     [:ledger/missing-account])
        (:bytea v-controller-root)
        (account/account-value-controller-root v-account-root)
        (:bytea v-expected-controller)
        (admission/admission-controller-root i-public-key)
        _ (pg/assert (== v-controller-root v-expected-controller)
                     [:ledger/controller-mismatch])
        (:bigint v-sequence)
        (value/integer-bigint
         (account/account-value-sequence-root v-account-root))
        (:text v-transition-error)
        (-/review-transition-error
         i-workspace-id-root i-candidate-root v-address-root
         i-expected-review-root i-decision i-recorded-at)
        _ (pg/assert [v-transition-error :is-null]
                     [:ledger/invalid-workspace-review-update
                      v-transition-error])
        (:bytea v-review-root)
        (-/workspace-review-put
         i-candidate-root v-address-root i-decision i-recorded-at)
        _ (pg/assert
           (or [i-expected-review-root :is-null]
               (not (== i-expected-review-root v-review-root)))
           [:ledger/noop-workspace-review-update])
        (:bytea v-intent-root)
        (-/workspace-review-intent-value
         i-workspace-id-root i-candidate-root v-address-root
         i-expected-review-root v-review-root)
        (:bytea v-op-root) (op/constant v-intent-root)
        (:bytea v-runtime-root) (value/put-integer "1")
        (:bytea v-payload)
        (transaction/transaction-signing-payload
         i-network v-address-root v-sequence
         v-op-root nil i-cost-limit v-runtime-root)]
    (return
     (pg/jsonb-build-object
      "address" (pg/encode v-address-root "hex")
      "sequence" v-sequence
      "workspace_id_root" (pg/encode i-workspace-id-root "hex")
      "candidate_root" (pg/encode i-candidate-root "hex")
      "scope" (-/review-scope i-workspace-id-root)
      "name" (-/review-ref-name i-candidate-root v-address-root)
      "expected_review_root"
      (scoped-ref/root-hex i-expected-review-root)
      "review_root" (pg/encode v-review-root "hex")
      "decision" i-decision
      "recorded_at" i-recorded-at
      "policy" "review-decision-v1"
      "intent_root" (pg/encode v-intent-root "hex")
      "operation_root" (pg/encode v-op-root "hex")
      "signing_payload" (pg/encode v-payload "hex")))))

(defn.pg ^{:- [:jsonb]}
  workspace-review-submit
  "Atomically admits one signed review decision and updates its reviewer ref."
  {:added "0.14"}
  [:text i-network
   :bytea i-public-key
   :bigint i-sequence
   :bytea i-workspace-id-root
   :bytea i-candidate-root
   :bytea i-expected-review-root
   :text i-decision
   :bigint i-recorded-at
   :bigint i-cost-limit
   :bytea i-signature]
  (let [o-head (block/head-lock i-network)
        _ (pg/assert [o-head :is-not-null] [:ledger/network-missing])
        _ (pg/assert (>= i-cost-limit 1) [:ledger/invalid-cost-limit])
        (:bytea v-previous-state)
        (:bytea (:->> o-head "state_root"))
        (:bigint v-previous-height)
        (:bigint (:->> o-head "height"))
        (:bytea v-address-root)
        (admission/admission-address-root i-public-key)
        (:bytea v-account-root)
        (state/state-account-root v-previous-state v-address-root)
        _ (pg/assert [v-account-root :is-not-null]
                     [:ledger/missing-account])
        (:bytea v-controller-root)
        (account/account-value-controller-root v-account-root)
        (:bytea v-expected-controller)
        (admission/admission-controller-root i-public-key)
        _ (pg/assert (== v-controller-root v-expected-controller)
                     [:ledger/controller-mismatch])
        (:bigint v-current-sequence)
        (value/integer-bigint
         (account/account-value-sequence-root v-account-root))
        _ (pg/assert (== v-current-sequence i-sequence)
                     [:ledger/sequence-conflict])
        (:text v-transition-error)
        (-/review-transition-error
         i-workspace-id-root i-candidate-root v-address-root
         i-expected-review-root i-decision i-recorded-at)
        _ (pg/assert [v-transition-error :is-null]
                     [:ledger/invalid-workspace-review-update
                      v-transition-error])
        (:bytea v-review-root)
        (-/workspace-review-put
         i-candidate-root v-address-root i-decision i-recorded-at)
        _ (pg/assert
           (or [i-expected-review-root :is-null]
               (not (== i-expected-review-root v-review-root)))
           [:ledger/noop-workspace-review-update])
        (:text v-scope) (-/review-scope i-workspace-id-root)
        (:text v-name)
        (-/review-ref-name i-candidate-root v-address-root)
        (:bytea v-intent-root)
        (-/workspace-review-intent-value
         i-workspace-id-root i-candidate-root v-address-root
         i-expected-review-root v-review-root)
        (:bytea v-op-root) (op/constant v-intent-root)
        (:bytea v-runtime-root) (value/put-integer "1")
        (:bytea v-signing-payload)
        (transaction/transaction-signing-payload
         i-network v-address-root i-sequence
         v-op-root nil i-cost-limit v-runtime-root)
        _ (pg/assert
           (crypto/signature-verify
            i-signature v-signing-payload i-public-key)
           [:ledger/invalid-workspace-review-signature])
        o-cas
        (scoped-ref/scoped-ref-compare-and-set
         v-scope v-name i-expected-review-root
         v-review-root v-address-root)
        (:text v-cas-status) (:text (:->> o-cas "status"))]
    (when (not (== v-cas-status "ok"))
      (return
       (|| o-cas
           (pg/jsonb-build-object
            "address" (pg/encode v-address-root "hex")
            "candidate_root" (pg/encode i-candidate-root "hex")
            "review_root" (pg/encode v-review-root "hex")
            "decision" i-decision
            "recorded_at" i-recorded-at
            "policy" "review-decision-v1"
            "intent_root" (pg/encode v-intent-root "hex")
            "sequence" i-sequence))))
    (let [(:bytea v-transaction-root)
          (transaction/transaction-put
           i-network v-address-root i-sequence
           v-op-root nil i-cost-limit v-runtime-root i-signature)
          (:bytea v-receipt-root)
          (block/block-execute-signed-transaction
           v-transaction-root i-network v-previous-state
           (+ v-previous-height 1) i-recorded-at)
          o-receipt
          (transaction/transaction-receipt-get v-receipt-root)
          _ (pg/assert [o-receipt :is-not-null]
                       [:ledger/missing-receipt])
          _ (pg/assert
             (and (== (:text (:->> o-receipt "status")) "ok")
                  (== (:bytea (:->> o-receipt "result_root"))
                      v-intent-root))
             [:ledger/workspace-review-receipt-mismatch])
          (:bytea v-state-root)
          (:bytea (:->> o-receipt "state_root"))
          (:bytea v-block-root)
          (block/block-commit
           i-network v-previous-height v-previous-state
           (+ v-previous-height 1)
           (:bytea (:->> o-head "block_root"))
           v-previous-state v-state-root i-recorded-at
           (admission/admission-proposer-root) nil
           (pg/jsonb-build-array
            (pg/encode v-transaction-root "hex")))
          o-bound
          (block/block-transaction-bind
           v-block-root 0 v-receipt-root)]
      (return
       (pg/jsonb-build-object
        "status" "ok"
        "address" (pg/encode v-address-root "hex")
        "sequence" i-sequence
        "workspace_id_root" (pg/encode i-workspace-id-root "hex")
        "candidate_root" (pg/encode i-candidate-root "hex")
        "scope" v-scope
        "name" v-name
        "expected_review_root"
        (scoped-ref/root-hex i-expected-review-root)
        "review_root" (pg/encode v-review-root "hex")
        "decision" i-decision
        "recorded_at" i-recorded-at
        "policy" "review-decision-v1"
        "ref_version" (:bigint (:->> o-cas "version"))
        "intent_root" (pg/encode v-intent-root "hex")
        "transaction_root" (pg/encode v-transaction-root "hex")
        "receipt_root" (pg/encode v-receipt-root "hex")
        "result_root"
        (pg/encode
         (:bytea (:->> o-receipt "result_root")) "hex")
        "state_root" (pg/encode v-state-root "hex")
        "block_root" (pg/encode v-block-root "hex"))))))
