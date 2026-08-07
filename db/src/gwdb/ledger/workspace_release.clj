(ns gwdb.ledger.workspace-release
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
            [gwdb.ledger.workspace-review :as workspace-review]
            [gwdb.ledger.workspace-acceptance :as workspace-acceptance]
            [gwdb.ledger.workspace-main :as workspace-main]))

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
             [gwdb.ledger.workspace-review :as workspace-review]
             [gwdb.ledger.workspace-acceptance :as workspace-acceptance]
             [gwdb.ledger.workspace-main :as workspace-main]]
   :config {:dbname "gw-ledger-test"}
   :import [["pgcrypto"] ["pgsodium"]]
   :static {:application ["gw"]
            :all {:schema ["gw_ledger"]}}})

(deftype.pg WorkspaceRelease
  "Rebuildable projection of one canonical immutable workspace release."
  {:added "0.17"}
  [:release-root      {:type :bytea :primary true}
   :workspace-id-root {:type :bytea :required true}
   :authority-root    {:type :bytea :required true}
   :version           {:type :text :required true}
   :candidate-root    {:type :bytea :required true}
   :policy-root       {:type :bytea :required true}
   :acceptance-root   {:type :bytea :required true}
   :recorded-at       {:type :long :required true}])

(defn.pg ^{:- [:text]}
  release-scope
  {:added "0.17"}
  [:bytea i-workspace-id-root]
  (return
   (workspace-admission/personal-scope i-workspace-id-root)))

(defn.pg ^{:- [:text]}
  release-name
  {:added "0.17"}
  [:text i-version]
  (return (|| "release/" i-version)))

(defn.pg ^{:- [:text]}
  release-id
  {:added "0.17"}
  [:bytea i-workspace-id-root :text i-version]
  (return
   (|| "release/"
       (workspace-admission/workspace-id-text i-workspace-id-root)
       "/" i-version)))

(defn.pg ^{:- [:bytea]}
  release-evidence-roots-value
  {:added "0.17"}
  [:bytea i-acceptance-root]
  (return
   (value/put-vector
    (pg/jsonb-build-array
     (pg/encode i-acceptance-root "hex")))))

(defn.pg ^{:- [:bytea]}
  release-extensions-value
  {:added "0.17"}
  [:bytea i-workspace-id-root
   :text i-version
   :bytea i-candidate-root
   :bytea i-acceptance-root]
  (let [(:bytea v-empty-map)
        (value/put-map (pg/jsonb-build-array))
        (:bytea v-workspace)
        (workspace/record-assoc
         v-empty-map "workspace/id" i-workspace-id-root)
        (:bytea v-version)
        (workspace/record-assoc
         v-workspace "release/version" (value/put-string i-version))
        (:bytea v-acceptance)
        (workspace/record-assoc
         v-version "release/acceptance-root" i-acceptance-root)
        (:bytea v-expected)
        (workspace/record-assoc
         v-acceptance "ref/expected-root" (value/put-nil))
        (:bytea v-desired)
        (workspace/record-assoc
         v-expected "ref/desired-root" i-candidate-root)]
    (return
     (workspace/record-assoc
      v-desired "ref/policy"
      (value/put-keyword "release-publication-v1")))))

(defn.pg ^{:- [:bytea]}
  workspace-release-value
  "Constructs one canonical create-only workspace release attestation."
  {:added "0.17"}
  [:bytea i-workspace-id-root
   :bytea i-authority-root
   :text i-version
   :bytea i-candidate-root
   :bytea i-policy-root
   :bytea i-acceptance-root
   :bigint i-recorded-at]
  (let [(:bytea v-empty-map)
        (value/put-map (pg/jsonb-build-array))
        (:bytea v-record)
        (workspace/record-start "attestation/claim")
        (:bytea v-version)
        (workspace/record-assoc
         v-record "record/version" (value/put-integer-number 1))
        (:bytea v-extensions)
        (workspace/record-assoc
         v-version "record/extensions"
         (-/release-extensions-value
          i-workspace-id-root i-version
          i-candidate-root i-acceptance-root))
        (:bytea v-id)
        (workspace/record-assoc
         v-extensions "attestation/id"
         (value/put-string
          (-/release-id i-workspace-id-root i-version)))
        (:bytea v-claim)
        (workspace/record-assoc
         v-id "attestation/claim"
         (value/put-keyword "workspace/release-published-v1"))
        (:bytea v-subject-id)
        (workspace/record-assoc
         v-claim "attestation/subject-id"
         (value/put-string (-/release-name i-version)))
        (:bytea v-subject-root)
        (workspace/record-assoc
         v-subject-id "attestation/subject-root" i-candidate-root)
        (:bytea v-context)
        (workspace/record-assoc
         v-subject-root "attestation/context-root" i-policy-root)
        (:bytea v-evidence-roots)
        (workspace/record-assoc
         v-context "attestation/evidence-roots"
         (-/release-evidence-roots-value i-acceptance-root))
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
         (value/put-keyword "workspace/release"))
        (:bytea v-audience)
        (workspace/record-assoc
         v-scope "attestation/audience"
         (value/put-keyword "workspace/members"))
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

(defn.pg workspace-release-row
  {:added "0.17"}
  [:bytea i-release-root]
  (return
   (pg/t:get -/WorkspaceRelease
             {:where {:release-root i-release-root}})))

(defn.pg ^{:- [:boolean]}
  block-ancestor
  "Checks that one block is on the parent chain ending at another block."
  {:added "0.17"}
  [:bytea i-ancestor-root :bytea i-descendant-root]
  (cond [i-descendant-root :is-null]
        (return false)

        (== i-ancestor-root i-descendant-root)
        (return true)

        :else
        (let [o-block (block/block-get i-descendant-root)]
          (cond [o-block :is-null]
                (return false)

                :else
                (return
                 (-/block-ancestor
                  i-ancestor-root
                  (:bytea (:->> o-block "parent_root"))))))))

(defn.pg accepted-main-evidence-row
  "Finds the successful receipt and block binding for an acceptance root."
  {:added "0.17"}
  [:bytea i-acceptance-root]
  (let [o-receipt
        (pg/t:get
         transaction/TransactionReceipt
         {:where {:status "ok"
                  :result-root i-acceptance-root}})]
    (return
     (pg/case [o-receipt :is-null]
              nil
              :else
              (pg/t:get
               block/BlockTransaction
               {:where {:receipt-root
                        (:bytea (:->> o-receipt "receipt_root"))}})))))

(defn.pg ^{:- [:text]}
  accepted-main-evidence-error
  "Proves an acceptance has an ok receipt bound to the canonical network chain."
  {:added "0.17"}
  [:text i-network :bytea i-acceptance-root]
  (let [o-acceptance
        (workspace-main/workspace-main-acceptance-row i-acceptance-root)
        o-receipt
        (pg/t:get
         transaction/TransactionReceipt
         {:where {:status "ok"
                  :result-root i-acceptance-root}})
        o-binding
        (pg/case [o-receipt :is-null]
                 nil
                 :else
                 (pg/t:get
                  block/BlockTransaction
                  {:where {:receipt-root
                           (:bytea (:->> o-receipt "receipt_root"))}}))
        o-block
        (pg/case [o-binding :is-null]
                 nil
                 :else
                 (block/block-get
                  (:bytea (:->> o-binding "block_root"))))
        o-transaction
        (pg/case [o-receipt :is-null]
                 nil
                 :else
                 (transaction/transaction-get
                  (:bytea (:->> o-receipt "transaction_root"))))
        o-head (block/head-get i-network)]
    (cond [o-acceptance :is-null]
          (return "workspace/release-acceptance-not-found")

          (not
           (workspace-main/workspace-main-acceptance-valid
            i-acceptance-root))
          (return "workspace/invalid-release-acceptance")

          [o-receipt :is-null]
          (return "workspace/release-acceptance-not-committed")

          [o-binding :is-null]
          (return "workspace/release-acceptance-receipt-not-bound")

          [o-block :is-null]
          (return "workspace/release-acceptance-block-not-found")

          [o-transaction :is-null]
          (return "workspace/release-acceptance-transaction-not-found")

          [o-head :is-null]
          (return "workspace/release-network-not-found")

          (not
           (== (:bytea (:->> o-binding "transaction_root"))
               (:bytea (:->> o-receipt "transaction_root"))))
          (return "workspace/release-acceptance-transaction-mismatch")

          (not
           (== (:bytea (:->> o-binding "receipt_root"))
               (:bytea (:->> o-receipt "receipt_root"))))
          (return "workspace/release-acceptance-receipt-mismatch")

          (not
           (== (:text (:->> o-block "network")) i-network))
          (return "workspace/release-acceptance-network-mismatch")

          (not
           (block/block-valid
            (:bytea (:->> o-binding "block_root"))))
          (return "workspace/invalid-release-acceptance-block")

          (not
           (-/block-ancestor
            (:bytea (:->> o-binding "block_root"))
            (:bytea (:->> o-head "block_root"))))
          (return "workspace/release-acceptance-not-canonical")

          (not
           (transaction/transaction-signed-valid
            (:bytea (:->> o-receipt "transaction_root"))
            i-network
            (:bytea (:->> o-block "previous_state_root"))))
          (return "workspace/invalid-release-acceptance-transaction")

          (not
           (== (:bytea (:->> o-receipt "previous_state_root"))
               (:bytea (:->> o-block "previous_state_root"))))
          (return "workspace/release-acceptance-previous-state-mismatch")

          (not
           (== (:bytea (:->> o-receipt "state_root"))
               (:bytea (:->> o-block "state_root"))))
          (return "workspace/release-acceptance-state-mismatch")

          (not
           (== (:bytea (:->> o-transaction "origin"))
               (:bytea (:->> o-acceptance "authority_root"))))
          (return "workspace/release-acceptance-origin-mismatch")

          :else
          (return nil))))

(defn.pg ^{:- [:boolean]}
  accepted-main-evidence-valid
  {:added "0.17"}
  [:text i-network :bytea i-acceptance-root]
  (return
   [(-/accepted-main-evidence-error
     i-network i-acceptance-root) :is-null]))

(defn.pg ^{:- [:text]}
  workspace-release-error
  "Returns the first canonical release projection failure, or SQL null."
  {:added "0.17"}
  [:bytea i-release-root]
  (cond (not
         (workspace/record-kind i-release-root "attestation/claim"))
        (return "workspace/invalid-release-record")

        (not (workspace/record-version-one i-release-root))
        (return "workspace/unsupported-release-version")

        :else
        (let [(:bytea v-id-root)
              (workspace/field i-release-root "attestation/id")
              (:bytea v-claim-root)
              (workspace/field i-release-root "attestation/claim")
              (:bytea v-subject-id-root)
              (workspace/field i-release-root "attestation/subject-id")
              (:bytea v-candidate-root)
              (workspace/field i-release-root "attestation/subject-root")
              (:bytea v-policy-root)
              (workspace/optional-field
               i-release-root "attestation/context-root")
              (:bytea v-evidence-roots-root)
              (workspace/field
               i-release-root "attestation/evidence-roots")
              o-evidence-vector (cell/cell-by-hash v-evidence-roots-root)
              (:integer v-evidence-count)
              (pg/case [o-evidence-vector :is-null]
                       -1
                       :else
                       (cell/cell-ref-count
                        v-evidence-roots-root "element"))
              (:bytea v-evidence-acceptance-root)
              (pg/case (== v-evidence-count 1)
                       (cell/cell-ref-child
                        v-evidence-roots-root 0 "element")
                       :else nil)
              (:bytea v-process-id-root)
              (workspace/optional-field
               i-release-root "attestation/process-run-id")
              (:bytea v-process-root)
              (workspace/optional-field
               i-release-root "attestation/process-run-root")
              (:bytea v-issuer-root)
              (workspace/field
               i-release-root "attestation/issuer-evidence")
              (:bytea v-authority-root)
              (workspace/field v-issuer-root "ledger/signer")
              (:bytea v-recorded-at-root)
              (workspace/field v-issuer-root "ledger/timestamp")
              (:bytea v-scope-root)
              (workspace/field i-release-root "attestation/scope")
              (:bytea v-audience-root)
              (workspace/field i-release-root "attestation/audience")
              (:bytea v-valid-from-root)
              (workspace/field i-release-root "attestation/valid-from")
              (:bytea v-valid-until-root)
              (workspace/optional-field
               i-release-root "attestation/valid-until")
              (:bytea v-revokes-root)
              (workspace/optional-field
               i-release-root "attestation/revokes-root")
              (:bytea v-metadata-root)
              (workspace/field i-release-root "attestation/metadata")
              (:bytea v-extensions-root)
              (workspace/field i-release-root "record/extensions")
              (:bytea v-workspace-id-root)
              (workspace/field v-extensions-root "workspace/id")
              (:bytea v-version-root)
              (workspace/field v-extensions-root "release/version")
              o-version-cell (cell/cell-by-hash v-version-root)
              (:text v-version)
              (pg/case (and [o-version-cell :is-not-null]
                            (== (:smallint
                                 (:->> o-version-cell "type_tag")) 5))
                       (convert-from
                        (:bytea (:->> o-version-cell "payload")) "UTF8")
                       :else nil)
              (:bytea v-acceptance-root)
              (workspace/field
               v-extensions-root "release/acceptance-root")
              (:bytea v-expected-root)
              (workspace/optional-field
               v-extensions-root "ref/expected-root")
              (:bytea v-desired-root)
              (workspace/field v-extensions-root "ref/desired-root")
              (:bytea v-ref-policy-root)
              (workspace/field v-extensions-root "ref/policy")
              (:bytea v-empty-map)
              (value/put-map (pg/jsonb-build-array))
              o-workspace (cell/cell-by-hash v-workspace-id-root)
              o-candidate (workspace/workspace-commit-row v-candidate-root)
              o-policy
              (workspace-acceptance/workspace-main-policy-row v-policy-root)
              o-acceptance
              (workspace-main/workspace-main-acceptance-row v-acceptance-root)
              o-recorded-at (cell/cell-by-hash v-recorded-at-root)]
          (cond (or [o-workspace :is-null]
                    (not
                     (== (:smallint (:->> o-workspace "type_tag")) 5)))
                (return "workspace/invalid-release-workspace-id")

                [v-version :is-null]
                (return "workspace/invalid-release-version-value")

                (= (pg/length v-version) 0)
                (return "workspace/missing-release-version")

                (not
                 (scoped-ref/ref-part-valid
                  (-/release-name v-version)))
                (return "workspace/invalid-release-ref-name")

                [o-candidate :is-null]
                (return "workspace/release-candidate-not-found")

                (not (workspace/workspace-commit-valid v-candidate-root))
                (return "workspace/invalid-release-candidate")

                (not
                 (== (:bytea (:->> o-candidate "workspace_id_root"))
                     v-workspace-id-root))
                (return "workspace/release-candidate-workspace-mismatch")

                [o-policy :is-null]
                (return "workspace/release-policy-not-found")

                (not
                 (workspace-acceptance/workspace-main-policy-valid
                  v-policy-root))
                (return "workspace/invalid-release-policy")

                [o-acceptance :is-null]
                (return "workspace/release-acceptance-not-found")

                (not
                 (workspace-main/workspace-main-acceptance-valid
                  v-acceptance-root))
                (return "workspace/invalid-release-acceptance")

                (not
                 (== (:bytea (:->> o-policy "workspace_id_root"))
                     v-workspace-id-root))
                (return "workspace/release-policy-workspace-mismatch")

                (not
                 (== (:bytea (:->> o-policy "authority_root"))
                     v-authority-root))
                (return "workspace/release-policy-authority-mismatch")

                (not
                 (== (:bytea (:->> o-acceptance "workspace_id_root"))
                     v-workspace-id-root))
                (return "workspace/release-acceptance-workspace-mismatch")

                (not
                 (== (:bytea (:->> o-acceptance "authority_root"))
                     v-authority-root))
                (return "workspace/release-acceptance-authority-mismatch")

                (not
                 (== (:bytea (:->> o-acceptance "candidate_root"))
                     v-candidate-root))
                (return "workspace/release-acceptance-candidate-mismatch")

                (not
                 (== (:bytea (:->> o-acceptance "policy_root"))
                     v-policy-root))
                (return "workspace/release-acceptance-policy-mismatch")

                (or [o-evidence-vector :is-null]
                    (not
                     (== (:smallint
                          (:->> o-evidence-vector "type_tag")) 10))
                    (not (== v-evidence-count 1)))
                (return "workspace/release-evidence-root-mismatch")

                (not (== v-evidence-acceptance-root v-acceptance-root))
                (return "workspace/release-evidence-root-mismatch")

                [v-process-id-root :is-not-null]
                (return "workspace/release-process-not-supported")

                [v-process-root :is-not-null]
                (return "workspace/release-process-not-supported")

                (not
                 (workspace/record-kind
                  v-issuer-root "ledger/evidence"))
                (return "workspace/invalid-release-evidence")

                (not
                 (workspace/record-version-one v-issuer-root))
                (return "workspace/unsupported-release-evidence")

                [(cell/cell-by-hash v-authority-root) :is-null]
                (return "workspace/release-authority-not-found")

                (or [o-recorded-at :is-null]
                    (not
                     (== (:smallint (:->> o-recorded-at "type_tag")) 2)))
                (return "workspace/invalid-release-recorded-at")

                [(workspace/optional-field
                  v-issuer-root "ledger/transaction-root") :is-not-null]
                (return "workspace/release-transaction-evidence-not-supported")

                [(workspace/optional-field
                  v-issuer-root "ledger/previous-head-root") :is-not-null]
                (return "workspace/release-head-evidence-not-supported")

                [(workspace/optional-field
                  v-issuer-root "ledger/contract-root") :is-not-null]
                (return "workspace/release-contract-evidence-not-supported")

                [(workspace/optional-field
                  v-issuer-root "ledger/template-root") :is-not-null]
                (return "workspace/release-template-evidence-not-supported")

                [(workspace/optional-field
                  v-issuer-root "ledger/global-state-root") :is-not-null]
                (return "workspace/release-state-evidence-not-supported")

                (not (== v-scope-root
                         (value/put-keyword "workspace/release")))
                (return "workspace/release-scope-mismatch")

                (not (== v-audience-root
                         (value/put-keyword "workspace/members")))
                (return "workspace/release-audience-mismatch")

                (not (== v-valid-from-root v-recorded-at-root))
                (return "workspace/release-valid-from-mismatch")

                [v-valid-until-root :is-not-null]
                (return "workspace/release-expiry-not-supported")

                [v-revokes-root :is-not-null]
                (return "workspace/release-revocation-not-supported")

                (not (== v-metadata-root v-empty-map))
                (return "workspace/release-metadata-not-supported")

                [v-expected-root :is-not-null]
                (return "workspace/release-not-create-only")

                (not (== v-desired-root v-candidate-root))
                (return "workspace/release-desired-root-mismatch")

                (not (== v-ref-policy-root
                         (value/put-keyword "release-publication-v1")))
                (return "workspace/unsupported-release-policy")

                :else
                (let [(:bigint v-recorded-at)
                      (value/integer-bigint v-recorded-at-root)
                      (:bytea v-reconstructed)
                      (-/workspace-release-value
                       v-workspace-id-root v-authority-root v-version
                       v-candidate-root v-policy-root v-acceptance-root
                       v-recorded-at)]
                  (cond (< v-recorded-at 0)
                        (return "workspace/invalid-release-recorded-at")

                        (not (== v-id-root
                                 (value/put-string
                                  (-/release-id
                                   v-workspace-id-root v-version))))
                        (return "workspace/release-id-not-derived")

                        (not (== v-claim-root
                                 (value/put-keyword
                                  "workspace/release-published-v1")))
                        (return "workspace/unsupported-release-claim")

                        (not (== v-subject-id-root
                                 (value/put-string
                                  (-/release-name v-version))))
                        (return "workspace/release-subject-id-mismatch")

                        (not (== v-issuer-root
                                 (workspace-review/review-recorded-evidence-value
                                  v-authority-root v-recorded-at)))
                        (return "workspace/noncanonical-release-evidence")

                        (not (== v-extensions-root
                                 (-/release-extensions-value
                                  v-workspace-id-root v-version
                                  v-candidate-root v-acceptance-root)))
                        (return "workspace/noncanonical-release-extensions")

                        (not (== i-release-root v-reconstructed))
                        (return "workspace/noncanonical-release")

                        :else
                        (return nil)))))))

(defn.pg ^{:- [:boolean]}
  workspace-release-valid
  {:added "0.17"}
  [:bytea i-release-root]
  (let [o-row (-/workspace-release-row i-release-root)]
    (when [o-row :is-null]
      (return false))
    (let [(:bytea v-workspace-id-root)
          (:bytea (:->> o-row "workspace_id_root"))
          (:bytea v-authority-root)
          (:bytea (:->> o-row "authority_root"))
          (:text v-version) (:text (:->> o-row "version"))
          (:bytea v-candidate-root)
          (:bytea (:->> o-row "candidate_root"))
          (:bytea v-policy-root)
          (:bytea (:->> o-row "policy_root"))
          (:bytea v-acceptance-root)
          (:bytea (:->> o-row "acceptance_root"))
          (:bigint v-recorded-at)
          (:bigint (:->> o-row "recorded_at"))]
      (return
       (and [(-/workspace-release-error i-release-root) :is-null]
            (== i-release-root
                (-/workspace-release-value
                 v-workspace-id-root v-authority-root v-version
                 v-candidate-root v-policy-root v-acceptance-root
                 v-recorded-at)))))))

(defn.pg ^{:- [:bytea]}
  workspace-release-import
  {:added "0.17"}
  [:bytea i-release-root]
  (let [o-existing (-/workspace-release-row i-release-root)]
    (when [o-existing :is-not-null]
      (pg/assert (-/workspace-release-valid i-release-root)
                 [:ledger/workspace-release-projection-conflict])
      (return i-release-root))
    (let [(:text v-error) (-/workspace-release-error i-release-root)
          _ (pg/assert [v-error :is-null]
                       [:ledger/invalid-workspace-release v-error])
          (:bytea v-extensions-root)
          (workspace/field i-release-root "record/extensions")
          (:bytea v-workspace-id-root)
          (workspace/field v-extensions-root "workspace/id")
          (:bytea v-version-root)
          (workspace/field v-extensions-root "release/version")
          (:text v-version)
          (convert-from
           (:bytea (:->> (cell/cell-by-hash v-version-root) "payload"))
           "UTF8")
          (:bytea v-candidate-root)
          (workspace/field i-release-root "attestation/subject-root")
          (:bytea v-policy-root)
          (workspace/field i-release-root "attestation/context-root")
          (:bytea v-acceptance-root)
          (workspace/field v-extensions-root "release/acceptance-root")
          (:bytea v-issuer-root)
          (workspace/field i-release-root "attestation/issuer-evidence")
          (:bytea v-authority-root)
          (workspace/field v-issuer-root "ledger/signer")
          (:bigint v-recorded-at)
          (value/integer-bigint
           (workspace/field v-issuer-root "ledger/timestamp"))
          o-insert
          (pg/t:insert
           -/WorkspaceRelease
           {:release-root i-release-root
            :workspace-id-root v-workspace-id-root
            :authority-root v-authority-root
            :version v-version
            :candidate-root v-candidate-root
            :policy-root v-policy-root
            :acceptance-root v-acceptance-root
            :recorded-at v-recorded-at})]
      (return i-release-root))))

(defn.pg ^{:- [:bytea]}
  workspace-release-put
  {:added "0.17"}
  [:bytea i-workspace-id-root
   :bytea i-authority-root
   :text i-version
   :bytea i-candidate-root
   :bytea i-policy-root
   :bytea i-acceptance-root
   :bigint i-recorded-at]
  (let [_ (pg/assert (and [i-version :is-not-null]
                          (> (pg/length i-version) 0))
                     [:ledger/invalid-release-version])
        _ (pg/assert
           (scoped-ref/ref-part-valid (-/release-name i-version))
           [:ledger/invalid-release-ref-name])
        _ (pg/assert (>= i-recorded-at 0)
                     [:ledger/invalid-release-recorded-at])
        (:bytea v-root)
        (-/workspace-release-value
         i-workspace-id-root i-authority-root i-version
         i-candidate-root i-policy-root i-acceptance-root
         i-recorded-at)]
    (return (-/workspace-release-import v-root))))

(defn.pg ^{:- [:text]}
  release-transition-error
  "Returns the first selected policy, main, acceptance or chain failure."
  {:added "0.17"}
  [:text i-network
   :bytea i-workspace-id-root
   :bytea i-authority-root
   :text i-version
   :bytea i-candidate-root
   :bytea i-policy-root
   :bytea i-acceptance-root]
  (let [o-workspace (cell/cell-by-hash i-workspace-id-root)
        o-candidate (workspace/workspace-commit-row i-candidate-root)
        o-policy
        (workspace-acceptance/workspace-main-policy-row i-policy-root)
        o-acceptance
        (workspace-main/workspace-main-acceptance-row i-acceptance-root)
        o-policy-ref
        (scoped-ref/scoped-ref-row
         (-/release-scope i-workspace-id-root)
         (workspace-acceptance/main-policy-ref-name))
        o-main-ref
        (scoped-ref/scoped-ref-row
         (-/release-scope i-workspace-id-root)
         (workspace-main/main-ref-name))]
    (cond (or [o-workspace :is-null]
              (not
               (== (:smallint (:->> o-workspace "type_tag")) 5)))
          (return "workspace/invalid-workspace-id")

          (or [i-version :is-null]
              (= (pg/length i-version) 0))
          (return "workspace/missing-release-version")

          (not
           (scoped-ref/ref-part-valid (-/release-name i-version)))
          (return "workspace/invalid-release-ref-name")

          [o-candidate :is-null]
          (return "workspace/release-candidate-not-found")

          (not (workspace/workspace-commit-valid i-candidate-root))
          (return "workspace/invalid-release-candidate")

          (not
           (== (:bytea (:->> o-candidate "workspace_id_root"))
               i-workspace-id-root))
          (return "workspace/release-candidate-workspace-mismatch")

          [o-policy :is-null]
          (return "workspace/release-policy-not-found")

          (not
           (workspace-acceptance/workspace-main-policy-valid i-policy-root))
          (return "workspace/invalid-release-policy")

          (not
           (== (:bytea (:->> o-policy "workspace_id_root"))
               i-workspace-id-root))
          (return "workspace/release-policy-workspace-mismatch")

          (not
           (== (:bytea (:->> o-policy "authority_root"))
               i-authority-root))
          (return "workspace/release-policy-authority-mismatch")

          [o-policy-ref :is-null]
          (return "workspace/release-policy-not-published")

          (not
           (== (:bytea (:->> o-policy-ref "root")) i-policy-root))
          (return "workspace/release-policy-not-published")

          (not
           (== (:bytea (:->> o-policy-ref "authorization_root"))
               i-authority-root))
          (return "workspace/release-policy-authorization-mismatch")

          [o-main-ref :is-null]
          (return "workspace/release-main-not-selected")

          (not
           (== (:bytea (:->> o-main-ref "root")) i-candidate-root))
          (return "workspace/release-candidate-not-current-main")

          (not
           (== (:bytea (:->> o-main-ref "authorization_root"))
               i-policy-root))
          (return "workspace/release-main-policy-mismatch")

          [o-acceptance :is-null]
          (return "workspace/release-acceptance-not-found")

          (not
           (workspace-main/workspace-main-acceptance-valid
            i-acceptance-root))
          (return "workspace/invalid-release-acceptance")

          (not
           (== (:bytea (:->> o-acceptance "workspace_id_root"))
               i-workspace-id-root))
          (return "workspace/release-acceptance-workspace-mismatch")

          (not
           (== (:bytea (:->> o-acceptance "authority_root"))
               i-authority-root))
          (return "workspace/release-acceptance-authority-mismatch")

          (not
           (== (:bytea (:->> o-acceptance "candidate_root"))
               i-candidate-root))
          (return "workspace/release-acceptance-candidate-mismatch")

          (not
           (== (:bytea (:->> o-acceptance "policy_root"))
               i-policy-root))
          (return "workspace/release-acceptance-policy-mismatch")

          :else
          (return
           (-/accepted-main-evidence-error
            i-network i-acceptance-root)))))

(defn.pg ^{:- [:jsonb]}
  workspace-release-signing-request
  "Returns standard transaction bytes for one immutable release version."
  {:added "0.17"}
  [:text i-network
   :bytea i-public-key
   :bytea i-workspace-id-root
   :text i-version
   :bytea i-candidate-root
   :bytea i-policy-root
   :bytea i-acceptance-root
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
        (-/release-transition-error
         i-network i-workspace-id-root v-address-root i-version
         i-candidate-root i-policy-root i-acceptance-root)
        _ (pg/assert [v-transition-error :is-null]
                     [:ledger/invalid-workspace-release
                      v-transition-error])
        (:bytea v-release-root)
        (-/workspace-release-put
         i-workspace-id-root v-address-root i-version
         i-candidate-root i-policy-root i-acceptance-root
         i-recorded-at)
        (:bytea v-op-root) (op/constant v-release-root)
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
      "scope" (-/release-scope i-workspace-id-root)
      "name" (-/release-name i-version)
      "expected_root" nil
      "version" i-version
      "candidate_root" (pg/encode i-candidate-root "hex")
      "policy_root" (pg/encode i-policy-root "hex")
      "acceptance_root" (pg/encode i-acceptance-root "hex")
      "recorded_at" i-recorded-at
      "policy" "release-publication-v1"
      "release_root" (pg/encode v-release-root "hex")
      "operation_root" (pg/encode v-op-root "hex")
      "signing_payload" (pg/encode v-payload "hex")))))

(defn.pg ^{:- [:jsonb]}
  workspace-release-submit
  "Atomically publishes one signed immutable release into the linear chain."
  {:added "0.17"}
  [:text i-network
   :bytea i-public-key
   :bigint i-sequence
   :bytea i-workspace-id-root
   :text i-version
   :bytea i-candidate-root
   :bytea i-policy-root
   :bytea i-acceptance-root
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
        (-/release-transition-error
         i-network i-workspace-id-root v-address-root i-version
         i-candidate-root i-policy-root i-acceptance-root)
        _ (pg/assert [v-transition-error :is-null]
                     [:ledger/invalid-workspace-release
                      v-transition-error])
        (:bytea v-release-root)
        (-/workspace-release-put
         i-workspace-id-root v-address-root i-version
         i-candidate-root i-policy-root i-acceptance-root
         i-recorded-at)
        (:bytea v-op-root) (op/constant v-release-root)
        (:bytea v-runtime-root) (value/put-integer "1")
        (:bytea v-signing-payload)
        (transaction/transaction-signing-payload
         i-network v-address-root i-sequence
         v-op-root nil i-cost-limit v-runtime-root)
        _ (pg/assert
           (crypto/signature-verify
            i-signature v-signing-payload i-public-key)
           [:ledger/invalid-workspace-release-signature])
        (:text v-scope) (-/release-scope i-workspace-id-root)
        (:text v-name) (-/release-name i-version)
        o-cas
        (scoped-ref/scoped-ref-compare-and-set
         v-scope v-name nil i-candidate-root i-policy-root)
        (:text v-cas-status) (:text (:->> o-cas "status"))]
    (when (not (== v-cas-status "ok"))
      (return
       (|| o-cas
           (pg/jsonb-build-object
            "address" (pg/encode v-address-root "hex")
            "workspace_id_root" (pg/encode i-workspace-id-root "hex")
            "version" i-version
            "candidate_root" (pg/encode i-candidate-root "hex")
            "policy_root" (pg/encode i-policy-root "hex")
            "acceptance_root" (pg/encode i-acceptance-root "hex")
            "recorded_at" i-recorded-at
            "policy" "release-publication-v1"
            "release_root" (pg/encode v-release-root "hex")
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
                      v-release-root))
             [:ledger/workspace-release-receipt-mismatch])
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
        "version" i-version
        "candidate_root" (pg/encode i-candidate-root "hex")
        "policy_root" (pg/encode i-policy-root "hex")
        "acceptance_root" (pg/encode i-acceptance-root "hex")
        "recorded_at" i-recorded-at
        "policy" "release-publication-v1"
        "release_root" (pg/encode v-release-root "hex")
        "ref_version" (:bigint (:->> o-cas "version"))
        "transaction_root" (pg/encode v-transaction-root "hex")
        "receipt_root" (pg/encode v-receipt-root "hex")
        "result_root"
        (pg/encode
         (:bytea (:->> o-receipt "result_root")) "hex")
        "state_root" (pg/encode v-state-root "hex")
        "block_root" (pg/encode v-block-root "hex"))))))
