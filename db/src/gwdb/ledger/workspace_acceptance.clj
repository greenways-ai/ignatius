(ns gwdb.ledger.workspace-acceptance
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
            [gwdb.ledger.workspace-review :as workspace-review]))

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
             [gwdb.ledger.workspace-review :as workspace-review]]
   :config {:dbname "gw-ledger-test"}
   :import [["pgcrypto"] ["pgsodium"]]
   :static {:application ["gw"]
            :all {:schema ["gw_ledger"]}}})

(deftype.pg WorkspaceMainPolicy
  "Rebuildable projection of one canonical immutable main policy."
  {:added "0.15"}
  [:policy-root         {:type :bytea :primary true}
   :workspace-id-root   {:type :bytea :required true}
   :authority-root      {:type :bytea :required true}
   :reviewer-roots-root {:type :bytea :required true}
   :recorded-at         {:type :long :required true}])

(defn.pg ^{:- [:text]}
  main-policy-scope
  {:added "0.15"}
  [:bytea i-workspace-id-root]
  (return
   (workspace-admission/personal-scope i-workspace-id-root)))

(defn.pg ^{:- [:text]
           :%% :sql
           :props [:immutable :parallel-safe]}
  main-policy-ref-name
  {:added "0.15"}
  []
  (return "policy/main"))

(defn.pg ^{:- [:text]}
  main-policy-id
  {:added "0.15"}
  [:bytea i-workspace-id-root :bytea i-authority-root]
  (return
   (|| "main-policy/"
       (workspace-admission/workspace-id-text i-workspace-id-root)
       "/"
       (pg/encode i-authority-root "hex"))))

(defn.pg ^{:- [:bytea]}
  main-policy-extensions-value
  {:added "0.15"}
  [:bytea i-reviewer-roots-root]
  (let [(:bytea v-empty-map)
        (value/put-map (pg/jsonb-build-array))
        (:bytea v-kind)
        (workspace/record-assoc
         v-empty-map "workspace/policy-kind"
         (value/put-keyword "unanimous-reviewers-v1"))]
    (return
     (workspace/record-assoc
      v-kind "workspace/reviewer-roots"
      i-reviewer-roots-root))))

(defn.pg ^{:- [:bytea]}
  workspace-main-policy-value
  "Constructs the canonical immutable `policy/main` attestation."
  {:added "0.15"}
  [:bytea i-workspace-id-root
   :bytea i-authority-root
   :bytea i-reviewer-roots-root
   :bigint i-recorded-at]
  (let [(:bytea v-empty-map)
        (value/put-map (pg/jsonb-build-array))
        (:bytea v-empty-vector)
        (value/put-vector (pg/jsonb-build-array))
        (:bytea v-record)
        (workspace/record-start "attestation/claim")
        (:bytea v-version)
        (workspace/record-assoc
         v-record "record/version" (value/put-integer-number 1))
        (:bytea v-extensions)
        (workspace/record-assoc
         v-version "record/extensions"
         (-/main-policy-extensions-value i-reviewer-roots-root))
        (:bytea v-id)
        (workspace/record-assoc
         v-extensions "attestation/id"
         (value/put-string
          (-/main-policy-id i-workspace-id-root i-authority-root)))
        (:bytea v-claim)
        (workspace/record-assoc
         v-id "attestation/claim"
         (value/put-keyword "workspace/main-policy-v1"))
        (:bytea v-subject-id)
        (workspace/record-assoc
         v-claim "attestation/subject-id" i-workspace-id-root)
        (:bytea v-subject-root)
        (workspace/record-assoc
         v-subject-id "attestation/subject-root" i-workspace-id-root)
        (:bytea v-context)
        (workspace/record-assoc
         v-subject-root "attestation/context-root" (value/put-nil))
        (:bytea v-evidence-roots)
        (workspace/record-assoc
         v-context "attestation/evidence-roots" v-empty-vector)
        (:bytea v-process-id)
        (workspace/record-assoc
         v-evidence-roots "attestation/process-run-id" (value/put-nil))
        (:bytea v-process-root)
        (workspace/record-assoc
         v-process-id "attestation/process-run-root" (value/put-nil))
        (:bytea v-issuer)
        (workspace/record-assoc
         v-process-root "attestation/issuer-evidence"
         (workspace-review/review-recorded-evidence-value
          i-authority-root i-recorded-at))
        (:bytea v-scope)
        (workspace/record-assoc
         v-issuer "attestation/scope"
         (value/put-keyword "workspace/main"))
        (:bytea v-audience)
        (workspace/record-assoc
         v-scope "attestation/audience"
         (value/put-keyword "workspace/reviewers"))
        (:bytea v-valid-from)
        (workspace/record-assoc
         v-audience "attestation/valid-from"
         (value/put-integer-number i-recorded-at))
        (:bytea v-valid-until)
        (workspace/record-assoc
         v-valid-from "attestation/valid-until" (value/put-nil))
        (:bytea v-revokes)
        (workspace/record-assoc
         v-valid-until "attestation/revokes-root" (value/put-nil))]
    (return
     (workspace/record-assoc
      v-revokes "attestation/metadata" v-empty-map))))

(defn.pg workspace-main-policy-row
  {:added "0.15"}
  [:bytea i-policy-root]
  (return
   (pg/t:get -/WorkspaceMainPolicy
             {:where {:policy-root i-policy-root}})))

(defn.pg ^{:- [:boolean]}
  reviewer-seen-before
  {:added "0.15"}
  [:bytea i-reviewer-roots-root
   :integer i-position
   :bytea i-reviewer-root]
  (cond (<= i-position 0)
        (return false)

        :else
        (let [(:integer v-previous) (- i-position 1)
              (:bytea v-root)
              (cell/cell-ref-child
               i-reviewer-roots-root v-previous "element")]
          (return
           (or (== v-root i-reviewer-root)
               (-/reviewer-seen-before
                i-reviewer-roots-root
                v-previous i-reviewer-root))))))

(defn.pg ^{:- [:text]}
  main-policy-reviewer-error-at
  {:added "0.15"}
  [:bytea i-reviewer-roots-root
   :integer i-position
   :integer i-count]
  (cond (>= i-position i-count)
        (return nil)

        :else
        (let [(:bytea v-reviewer-root)
              (cell/cell-ref-child
               i-reviewer-roots-root i-position "element")]
          (cond [(cell/cell-by-hash v-reviewer-root) :is-null]
                (return "workspace/main-policy-reviewer-not-found")

                (-/reviewer-seen-before
                 i-reviewer-roots-root i-position v-reviewer-root)
                (return "workspace/main-policy-duplicate-reviewer")

                :else
                (return
                 (-/main-policy-reviewer-error-at
                  i-reviewer-roots-root
                  (+ i-position 1) i-count))))))

(defn.pg ^{:- [:text]}
  main-policy-reviewer-error
  {:added "0.15"}
  [:bytea i-reviewer-roots-root]
  (let [o-vector (cell/cell-by-hash i-reviewer-roots-root)]
    (cond [o-vector :is-null]
          (return "workspace/main-policy-reviewers-not-found")

          (not
           (== (:smallint (:->> o-vector "type_tag")) 10))
          (return "workspace/main-policy-reviewers-not-vector")

          :else
          (let [(:integer v-count)
                (cell/cell-ref-count
                 i-reviewer-roots-root "element")]
            (cond (= v-count 0)
                  (return "workspace/main-policy-missing-reviewers")

                  :else
                  (return
                   (-/main-policy-reviewer-error-at
                    i-reviewer-roots-root 0 v-count)))))))

(defn.pg ^{:- [:text]}
  workspace-main-policy-error
  "Returns the first canonical main-policy failure, or SQL null."
  {:added "0.15"}
  [:bytea i-policy-root]
  (cond (not
         (workspace/record-kind
          i-policy-root "attestation/claim"))
        (return "workspace/invalid-main-policy-record")

        (not (workspace/record-version-one i-policy-root))
        (return "workspace/unsupported-main-policy-version")

        :else
        (let [(:bytea v-id-root)
              (workspace/field i-policy-root "attestation/id")
              (:bytea v-claim-root)
              (workspace/field i-policy-root "attestation/claim")
              (:bytea v-subject-id-root)
              (workspace/field i-policy-root "attestation/subject-id")
              (:bytea v-workspace-id-root)
              (workspace/field i-policy-root "attestation/subject-root")
              (:bytea v-context-root)
              (workspace/optional-field
               i-policy-root "attestation/context-root")
              (:bytea v-evidence-roots-root)
              (workspace/field
               i-policy-root "attestation/evidence-roots")
              (:bytea v-process-id-root)
              (workspace/optional-field
               i-policy-root "attestation/process-run-id")
              (:bytea v-process-root)
              (workspace/optional-field
               i-policy-root "attestation/process-run-root")
              (:bytea v-issuer-root)
              (workspace/field
               i-policy-root "attestation/issuer-evidence")
              (:bytea v-authority-root)
              (workspace/field v-issuer-root "ledger/signer")
              (:bytea v-recorded-at-root)
              (workspace/field v-issuer-root "ledger/timestamp")
              (:bytea v-scope-root)
              (workspace/field i-policy-root "attestation/scope")
              (:bytea v-audience-root)
              (workspace/field i-policy-root "attestation/audience")
              (:bytea v-valid-from-root)
              (workspace/field i-policy-root "attestation/valid-from")
              (:bytea v-valid-until-root)
              (workspace/optional-field
               i-policy-root "attestation/valid-until")
              (:bytea v-revokes-root)
              (workspace/optional-field
               i-policy-root "attestation/revokes-root")
              (:bytea v-metadata-root)
              (workspace/field i-policy-root "attestation/metadata")
              (:bytea v-extensions-root)
              (workspace/field i-policy-root "record/extensions")
              (:bytea v-reviewer-roots-root)
              (workspace/field
               v-extensions-root "workspace/reviewer-roots")
              (:bytea v-policy-kind-root)
              (workspace/field
               v-extensions-root "workspace/policy-kind")
              (:bytea v-empty-map)
              (value/put-map (pg/jsonb-build-array))
              o-workspace (cell/cell-by-hash v-workspace-id-root)
              o-evidence-vector
              (cell/cell-by-hash v-evidence-roots-root)
              o-recorded-at (cell/cell-by-hash v-recorded-at-root)]
          (cond (or [o-workspace :is-null]
                    (not
                     (== (:smallint (:->> o-workspace "type_tag")) 5)))
                (return "workspace/invalid-main-policy-workspace-id")

                (not (== v-subject-id-root v-workspace-id-root))
                (return "workspace/main-policy-subject-id-mismatch")

                (not (== v-claim-root
                         (value/put-keyword
                          "workspace/main-policy-v1")))
                (return "workspace/unsupported-main-policy-claim")

                [v-context-root :is-not-null]
                (return "workspace/main-policy-context-not-supported")

                (or [o-evidence-vector :is-null]
                    (not
                     (== (:smallint
                          (:->> o-evidence-vector "type_tag")) 10))
                    (not
                     (== (cell/cell-ref-count
                          v-evidence-roots-root "element") 0)))
                (return "workspace/main-policy-evidence-not-empty")

                [v-process-id-root :is-not-null]
                (return "workspace/main-policy-process-not-supported")

                [v-process-root :is-not-null]
                (return "workspace/main-policy-process-not-supported")

                (not
                 (workspace/record-kind
                  v-issuer-root "ledger/evidence"))
                (return "workspace/invalid-main-policy-evidence")

                (not
                 (workspace/record-version-one v-issuer-root))
                (return "workspace/unsupported-main-policy-evidence")

                [(cell/cell-by-hash v-authority-root) :is-null]
                (return "workspace/main-policy-authority-not-found")

                (or [o-recorded-at :is-null]
                    (not
                     (== (:smallint
                          (:->> o-recorded-at "type_tag")) 2)))
                (return "workspace/invalid-main-policy-recorded-at")

                (not (== v-scope-root
                         (value/put-keyword "workspace/main")))
                (return "workspace/main-policy-scope-mismatch")

                (not (== v-audience-root
                         (value/put-keyword "workspace/reviewers")))
                (return "workspace/main-policy-audience-mismatch")

                (not (== v-valid-from-root v-recorded-at-root))
                (return "workspace/main-policy-valid-from-mismatch")

                [v-valid-until-root :is-not-null]
                (return "workspace/main-policy-expiry-not-supported")

                [v-revokes-root :is-not-null]
                (return "workspace/main-policy-revocation-not-supported")

                (not (== v-metadata-root v-empty-map))
                (return "workspace/main-policy-metadata-not-supported")

                (not (== v-policy-kind-root
                         (value/put-keyword
                          "unanimous-reviewers-v1")))
                (return "workspace/unsupported-main-policy-kind")

                :else
                (let [(:text v-reviewer-error)
                      (-/main-policy-reviewer-error
                       v-reviewer-roots-root)
                      (:bigint v-recorded-at)
                      (value/integer-bigint v-recorded-at-root)
                      (:bytea v-reconstructed)
                      (-/workspace-main-policy-value
                       v-workspace-id-root v-authority-root
                       v-reviewer-roots-root v-recorded-at)]
                  (cond [v-reviewer-error :is-not-null]
                        (return v-reviewer-error)

                        (< v-recorded-at 0)
                        (return "workspace/invalid-main-policy-recorded-at")

                        (not (== v-id-root
                                 (value/put-string
                                  (-/main-policy-id
                                   v-workspace-id-root
                                   v-authority-root))))
                        (return "workspace/main-policy-id-not-derived")

                        (not (== v-issuer-root
                                 (workspace-review/review-recorded-evidence-value
                                  v-authority-root v-recorded-at)))
                        (return "workspace/noncanonical-main-policy-evidence")

                        (not (== v-extensions-root
                                 (-/main-policy-extensions-value
                                  v-reviewer-roots-root)))
                        (return "workspace/noncanonical-main-policy-extensions")

                        (not (== i-policy-root v-reconstructed))
                        (return "workspace/noncanonical-main-policy")

                        :else
                        (return nil)))))))

(defn.pg ^{:- [:boolean]}
  workspace-main-policy-valid
  {:added "0.15"}
  [:bytea i-policy-root]
  (let [o-row (-/workspace-main-policy-row i-policy-root)]
    (when [o-row :is-null]
      (return false))
    (let [(:bytea v-workspace-id-root)
          (:bytea (:->> o-row "workspace_id_root"))
          (:bytea v-authority-root)
          (:bytea (:->> o-row "authority_root"))
          (:bytea v-reviewer-roots-root)
          (:bytea (:->> o-row "reviewer_roots_root"))
          (:bigint v-recorded-at)
          (:bigint (:->> o-row "recorded_at"))]
      (return
       (and [(-/workspace-main-policy-error i-policy-root) :is-null]
            (== i-policy-root
                (-/workspace-main-policy-value
                 v-workspace-id-root v-authority-root
                 v-reviewer-roots-root v-recorded-at)))))))

(defn.pg ^{:- [:bytea]}
  workspace-main-policy-import
  {:added "0.15"}
  [:bytea i-policy-root]
  (let [o-existing (-/workspace-main-policy-row i-policy-root)]
    (when [o-existing :is-not-null]
      (pg/assert (-/workspace-main-policy-valid i-policy-root)
                 [:ledger/workspace-main-policy-projection-conflict])
      (return i-policy-root))
    (let [(:text v-error)
          (-/workspace-main-policy-error i-policy-root)
          _ (pg/assert [v-error :is-null]
                       [:ledger/invalid-workspace-main-policy v-error])
          (:bytea v-workspace-id-root)
          (workspace/field i-policy-root "attestation/subject-root")
          (:bytea v-issuer-root)
          (workspace/field i-policy-root "attestation/issuer-evidence")
          (:bytea v-authority-root)
          (workspace/field v-issuer-root "ledger/signer")
          (:bigint v-recorded-at)
          (value/integer-bigint
           (workspace/field v-issuer-root "ledger/timestamp"))
          (:bytea v-extensions-root)
          (workspace/field i-policy-root "record/extensions")
          (:bytea v-reviewer-roots-root)
          (workspace/field
           v-extensions-root "workspace/reviewer-roots")
          o-insert
          (pg/t:insert
           -/WorkspaceMainPolicy
           {:policy-root i-policy-root
            :workspace-id-root v-workspace-id-root
            :authority-root v-authority-root
            :reviewer-roots-root v-reviewer-roots-root
            :recorded-at v-recorded-at})]
      (return i-policy-root))))

(defn.pg ^{:- [:bytea]}
  workspace-main-policy-put
  {:added "0.15"}
  [:bytea i-workspace-id-root
   :bytea i-authority-root
   :bytea i-reviewer-roots-root
   :bigint i-recorded-at]
  (let [(:text v-reviewer-error)
        (-/main-policy-reviewer-error i-reviewer-roots-root)
        _ (pg/assert [v-reviewer-error :is-null]
                     [:ledger/invalid-main-policy-reviewers
                      v-reviewer-error])
        _ (pg/assert (>= i-recorded-at 0)
                     [:ledger/invalid-main-policy-recorded-at])
        (:bytea v-root)
        (-/workspace-main-policy-value
         i-workspace-id-root i-authority-root
         i-reviewer-roots-root i-recorded-at)]
    (return (-/workspace-main-policy-import v-root))))

(defn.pg ^{:- [:text]}
  main-policy-transition-error
  {:added "0.15"}
  [:bytea i-workspace-id-root
   :bytea i-reviewer-roots-root
   :bigint i-recorded-at]
  (let [o-workspace (cell/cell-by-hash i-workspace-id-root)
        (:text v-reviewer-error)
        (-/main-policy-reviewer-error i-reviewer-roots-root)]
    (cond (or [o-workspace :is-null]
              (not
               (== (:smallint (:->> o-workspace "type_tag")) 5)))
          (return "workspace/invalid-workspace-id")

          [v-reviewer-error :is-not-null]
          (return v-reviewer-error)

          (< i-recorded-at 0)
          (return "workspace/invalid-main-policy-recorded-at")

          (not
           (scoped-ref/ref-part-valid
            (-/main-policy-scope i-workspace-id-root)))
          (return "workspace/invalid-main-policy-scope")

          (not
           (scoped-ref/ref-part-valid
            (-/main-policy-ref-name)))
          (return "workspace/invalid-main-policy-ref-name")

          :else
          (return nil))))

(defn.pg ^{:- [:jsonb]}
  workspace-main-policy-signing-request
  "Returns standard transaction bytes for create-only policy publication."
  {:added "0.15"}
  [:text i-network
   :bytea i-public-key
   :bytea i-workspace-id-root
   :bytea i-reviewer-roots-root
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
        (-/main-policy-transition-error
         i-workspace-id-root i-reviewer-roots-root i-recorded-at)
        _ (pg/assert [v-transition-error :is-null]
                     [:ledger/invalid-workspace-main-policy
                      v-transition-error])
        (:bytea v-policy-root)
        (-/workspace-main-policy-put
         i-workspace-id-root v-address-root
         i-reviewer-roots-root i-recorded-at)
        (:bytea v-op-root) (op/constant v-policy-root)
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
      "scope" (-/main-policy-scope i-workspace-id-root)
      "name" (-/main-policy-ref-name)
      "expected_root" nil
      "reviewer_roots_root" (pg/encode i-reviewer-roots-root "hex")
      "recorded_at" i-recorded-at
      "policy" "unanimous-reviewers-v1"
      "policy_root" (pg/encode v-policy-root "hex")
      "operation_root" (pg/encode v-op-root "hex")
      "signing_payload" (pg/encode v-payload "hex")))))

(defn.pg ^{:- [:jsonb]}
  workspace-main-policy-submit
  "Atomically publishes the signed immutable v1 policy and one linear block."
  {:added "0.15"}
  [:text i-network
   :bytea i-public-key
   :bigint i-sequence
   :bytea i-workspace-id-root
   :bytea i-reviewer-roots-root
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
        (-/main-policy-transition-error
         i-workspace-id-root i-reviewer-roots-root i-recorded-at)
        _ (pg/assert [v-transition-error :is-null]
                     [:ledger/invalid-workspace-main-policy
                      v-transition-error])
        (:bytea v-policy-root)
        (-/workspace-main-policy-put
         i-workspace-id-root v-address-root
         i-reviewer-roots-root i-recorded-at)
        (:bytea v-op-root) (op/constant v-policy-root)
        (:bytea v-runtime-root) (value/put-integer "1")
        (:bytea v-signing-payload)
        (transaction/transaction-signing-payload
         i-network v-address-root i-sequence
         v-op-root nil i-cost-limit v-runtime-root)
        _ (pg/assert
           (crypto/signature-verify
            i-signature v-signing-payload i-public-key)
           [:ledger/invalid-workspace-main-policy-signature])
        (:text v-scope) (-/main-policy-scope i-workspace-id-root)
        (:text v-name) (-/main-policy-ref-name)
        o-cas
        (scoped-ref/scoped-ref-compare-and-set
         v-scope v-name nil v-policy-root v-address-root)
        (:text v-cas-status) (:text (:->> o-cas "status"))]
    (when (not (== v-cas-status "ok"))
      (return
       (|| o-cas
           (pg/jsonb-build-object
            "address" (pg/encode v-address-root "hex")
            "reviewer_roots_root"
            (pg/encode i-reviewer-roots-root "hex")
            "recorded_at" i-recorded-at
            "policy" "unanimous-reviewers-v1"
            "policy_root" (pg/encode v-policy-root "hex")
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
                      v-policy-root))
             [:ledger/workspace-main-policy-receipt-mismatch])
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
        "scope" v-scope
        "name" v-name
        "expected_root" nil
        "reviewer_roots_root" (pg/encode i-reviewer-roots-root "hex")
        "recorded_at" i-recorded-at
        "policy" "unanimous-reviewers-v1"
        "policy_root" (pg/encode v-policy-root "hex")
        "ref_version" (:bigint (:->> o-cas "version"))
        "transaction_root" (pg/encode v-transaction-root "hex")
        "receipt_root" (pg/encode v-receipt-root "hex")
        "result_root"
        (pg/encode
         (:bytea (:->> o-receipt "result_root")) "hex")
        "state_root" (pg/encode v-state-root "hex")
        "block_root" (pg/encode v-block-root "hex"))))))
