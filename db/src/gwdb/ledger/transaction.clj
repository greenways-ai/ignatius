(ns gwdb.ledger.transaction
  (:require [tahto.core :as l]
            [postgres.core :as pg]
            [gwdb.ledger.cell :as cell]
            [gwdb.ledger.codec :as codec]
            [gwdb.ledger.crypto :as crypto]
            [gwdb.ledger.value :as value]
            [gwdb.ledger.account :as account]
            [gwdb.ledger.state :as state]
            [gwdb.ledger.op :as op]
            [gwdb.ledger.context :as context]
            [gwdb.ledger.protocol-runtime :as protocol-runtime]))

(l/script :postgres
  {:require [[postgres.core :as pg]
             [gwdb.ledger.cell :as cell]
             [gwdb.ledger.codec :as codec]
             [gwdb.ledger.crypto :as crypto]
             [gwdb.ledger.value :as value]
             [gwdb.ledger.account :as account]
             [gwdb.ledger.state :as state]
             [gwdb.ledger.op :as op]
             [gwdb.ledger.context :as context]
             [gwdb.ledger.protocol-runtime :as protocol-runtime]]
   :config {:dbname "gw-ledger-test"}
   :import [["pgcrypto"]]
   :static {:application ["gw"]
            :all {:schema ["gw_ledger"]}}})

(deftype.pg Transaction
  "Rebuildable descriptor for an authoritative canonical transaction value."
  {:added "0.2"}
  [:transaction-root    {:type :bytea :primary true}
   :transaction-version {:type :smallint :required true}
   :network             {:type :text :required true
                         :sql {:unique ["network-origin-sequence"]}}
   :origin              {:type :bytea :required true
                         :sql {:unique ["network-origin-sequence"]}}
   :sequence            {:type :long :required true
                         :sql {:unique ["network-origin-sequence"]}}
   :op-root             {:type :bytea :required true}
   :form-root           {:type :bytea}
   :cost-limit          {:type :long :required true}
   :runtime-root        {:type :bytea :required true}
   :signature           {:type :bytea}])

(deftype.pg TransactionReceipt
  "Append-only projection of a canonical transaction execution receipt."
  {:added "0.2"}
  [:receipt-root        {:type :bytea :primary true}
   :transaction-root    {:type :bytea :required true}
   :status              {:type :text :required true}
   :result-root         {:type :bytea}
   :previous-state-root {:type :bytea :required true}
   :state-root          {:type :bytea :required true}
   :cost-used           {:type :long :required true}
   :error-code          {:type :text}])

(defn.pg ^{:- [:text]}
  transaction-root-hex
  {:added "0.2"}
  [:bytea i-root]
  (return (pg/case [i-root :is-null] "-" :else (pg/encode i-root "hex"))))

(defn.pg ^{:- [:bytea]}
  transaction-signing-payload
  "Stable v1 bytes signed by the account controller.  This deliberately
   excludes the detached signature and transaction root."
  {:added "0.2"}
  [:text i-network :bytea i-origin :bigint i-sequence :bytea i-op-root
   :bytea i-form-root :bigint i-cost-limit :bytea i-runtime-root]
  (return
   (pg/decode
    (|| "R:transaction-signing:1:8:" i-network ":"
        (-/transaction-root-hex i-origin) ":" i-sequence ":"
        (-/transaction-root-hex i-op-root) ":"
        (-/transaction-root-hex i-form-root) ":" i-cost-limit ":"
        (-/transaction-root-hex i-runtime-root))
    "escape")))

(defn.pg ^{:- [:bytea]}
  transaction-payload
  "Builds the immutable signed transaction envelope from canonical components."
  {:added "0.3"}
  [:text i-network :bytea i-origin :bigint i-sequence :bytea i-op-root
   :bytea i-form-root :bigint i-cost-limit :bytea i-runtime-root
   :bytea i-signature]
  (return
   (pg/decode
    (|| "R:transaction:1:9:" i-network ":"
        (-/transaction-root-hex i-origin) ":" i-sequence ":"
        (-/transaction-root-hex i-op-root)
        (-/transaction-root-hex i-form-root) ":" i-cost-limit ":"
        (-/transaction-root-hex i-runtime-root)
        (-/transaction-root-hex i-signature))
    "escape")))

(defn.pg ^{:- [:bytea]} transaction-put
  "Commits one validated canonical transaction descriptor."
  {:added "0.2"}
  [:text i-network :bytea i-origin :bigint i-sequence :bytea i-op-root
   :bytea i-form-root :bigint i-cost-limit :bytea i-runtime-root
   :bytea i-signature]
  (let [o-origin (cell/cell-by-hash i-origin)
        o-op (cell/cell-by-hash i-op-root)
        o-runtime (cell/cell-by-hash i-runtime-root)
        o-form (cell/cell-by-hash i-form-root)
        _ (pg/assert [(pg/regexp-match i-network "^[a-z0-9._-]+$") :is-not-null]
                     [:ledger/invalid-network])
        _ (pg/assert [o-origin :is-not-null] [:ledger/missing-transaction-origin])
        _ (pg/assert (and [o-op :is-not-null]
                          (== (:smallint (:->> o-op "type_tag")) 17))
                     [:ledger/transaction-op-not-operation])
        _ (pg/assert [o-runtime :is-not-null] [:ledger/missing-runtime-root])
        _ (pg/assert (or [i-form-root :is-null] [o-form :is-not-null])
                     [:ledger/missing-form-root])
        _ (pg/assert (and (>= i-sequence 0) (>= i-cost-limit 1))
                     [:ledger/invalid-transaction-bounds])
        _ (pg/assert (or [i-signature :is-null]
                         (crypto/signature-valid i-signature))
                     [:ledger/invalid-transaction-signature])
        (:bytea v-payload) (-/transaction-payload
                             i-network i-origin i-sequence i-op-root i-form-root
                             i-cost-limit i-runtime-root i-signature)
        (:bytea v-root) (cell/cell-put (codec/canonical-hash 14 v-payload)
                                        1 14 v-payload)
        o-origin-ref (cell/cell-ref-put v-root 0 "origin" i-origin)
        o-op-ref (cell/cell-ref-put v-root 1 "op" i-op-root)
        o-runtime-ref (cell/cell-ref-put v-root 2 "runtime" i-runtime-root)
        o-form-ref (pg/case [i-form-root :is-null] nil
                            :else (cell/cell-ref-put v-root 3 "form" i-form-root))
        o-upsert (pg/t:upsert -/Transaction
                               {:transaction-root v-root
                                :transaction-version 1 :network i-network
                                :origin i-origin :sequence i-sequence
                                :op-root i-op-root :form-root i-form-root
                                :cost-limit i-cost-limit :runtime-root i-runtime-root
                                :signature i-signature})]
    (return v-root)))

(defn.pg transaction-get
  {:added "0.2"}
  [:bytea i-transaction-root]
  (let [o-row (pg/t:get -/Transaction {:where {:transaction-root i-transaction-root}})]
    (return o-row)))

(defn.pg ^{:- [:boolean]}
  transaction-root-valid
  "Verifies the canonical transaction cell against its rebuildable descriptor."
  {:added "0.2"}
  [:bytea i-transaction-root]
  (let [o-cell (cell/cell-by-hash i-transaction-root)
        o-tx (-/transaction-get i-transaction-root)
        _ (when (or [o-cell :is-null] [o-tx :is-null]) (return false))
        (:bytea v-payload)
        (-/transaction-payload
         (:text (:->> o-tx "network")) (:bytea (:->> o-tx "origin"))
         (:bigint (:->> o-tx "sequence")) (:bytea (:->> o-tx "op_root"))
         (:bytea (:->> o-tx "form_root")) (:bigint (:->> o-tx "cost_limit"))
         (:bytea (:->> o-tx "runtime_root")) (:bytea (:->> o-tx "signature")))]
    (return (and (== (:smallint (:->> o-cell "type_tag")) 14)
                 (== (:bytea (:->> o-cell "payload")) v-payload)
                 (codec/verify i-transaction-root 14 v-payload)
                 (== (cell/cell-ref-count i-transaction-root "origin") 1)
                 (== (cell/cell-ref-count i-transaction-root "op") 1)
                 (== (cell/cell-ref-count i-transaction-root "runtime") 1)))))

(defn.pg ^{:- [:boolean]}
  transaction-signature-valid
  "Verifies a transaction against the controller committed in its prior state."
  {:added "0.3"}
  [:bytea i-transaction-root :bytea i-state-root]
  (let [o-tx (-/transaction-get i-transaction-root)
        (:bytea v-account-root)
        (pg/case [o-tx :is-null] nil
                 :else (state/state-account-root
                        i-state-root (:bytea (:->> o-tx "origin"))))
        (:bytea v-controller-root)
        (pg/case [v-account-root :is-null] nil
                 :else (account/account-value-controller-root v-account-root))
        o-controller (cell/cell-by-hash v-controller-root)
        (:bytea v-message)
        (pg/case [o-tx :is-null] nil
                 :else (-/transaction-signing-payload
                        (:text (:->> o-tx "network")) (:bytea (:->> o-tx "origin"))
                        (:bigint (:->> o-tx "sequence")) (:bytea (:->> o-tx "op_root"))
                        (:bytea (:->> o-tx "form_root")) (:bigint (:->> o-tx "cost_limit"))
                        (:bytea (:->> o-tx "runtime_root"))))]
    (return (and [o-tx :is-not-null]
                 [v-account-root :is-not-null]
                 (crypto/public-key-root-valid v-controller-root)
                 (crypto/signature-verify
                  (:bytea (:->> o-tx "signature")) v-message
                  (:bytea (:->> o-controller "payload")))))))

(defn.pg ^{:- [:boolean]}
  transaction-valid
  "Checks a transaction entirely against a supplied immutable prior state."
  {:added "0.2"}
  [:bytea i-transaction-root :text i-network :bytea i-state-root]
  (let [o-tx (-/transaction-get i-transaction-root)
        (:bytea v-account-root)
        (pg/case [o-tx :is-null] nil
                 :else (state/state-account-root
                        i-state-root (:bytea (:->> o-tx "origin"))))]
    (return (and [o-tx :is-not-null]
                 (-/transaction-root-valid i-transaction-root)
                 (state/state-root-valid i-state-root)
                 (== (:text (:->> o-tx "network")) i-network)
                 (op/op-valid (:bytea (:->> o-tx "op_root")))
                 [v-account-root :is-not-null]
                 (== (:bigint (:->> o-tx "sequence"))
                     (value/integer-bigint
                      (account/account-value-sequence-root v-account-root)))
                 (>= (:bigint (:->> o-tx "cost_limit")) 1)))))

(defn.pg ^{:- [:boolean]}
  transaction-signed-valid
  "Strict public-admission validation.  Legacy internal fixtures may use
   transaction-valid while the public API always requires this predicate."
  {:added "0.3"}
  [:bytea i-transaction-root :text i-network :bytea i-state-root]
  (return (and (-/transaction-valid i-transaction-root i-network i-state-root)
               (-/transaction-signature-valid i-transaction-root i-state-root))))

(defn.pg ^{:- [:bytea]}
  receipt-payload
  {:added "0.2"}
  [:bytea i-transaction-root :text i-status :bytea i-result-root
   :bytea i-previous-state-root :bytea i-state-root :bigint i-cost-used
   :text i-error-code]
  (return
   (pg/decode
    (|| "R:receipt:1:7:"
        (-/transaction-root-hex i-transaction-root) i-status ":"
        (-/transaction-root-hex i-result-root)
        (-/transaction-root-hex i-previous-state-root)
        (-/transaction-root-hex i-state-root) i-cost-used ":"
        (pg/case [i-error-code :is-null] "-" :else i-error-code))
    "escape")))

(defn.pg ^{:- [:bytea]} transaction-receipt-put
  "Commits an execution receipt as a canonical immutable record."
  {:added "0.2"}
  [:bytea i-transaction-root :text i-status :bytea i-result-root
   :bytea i-previous-state-root :bytea i-state-root :bigint i-cost-used
   :text i-error-code]
  (let [(:bytea v-payload) (-/receipt-payload
                             i-transaction-root i-status i-result-root
                             i-previous-state-root i-state-root i-cost-used
                             i-error-code)
        (:bytea v-root) (cell/cell-put (codec/canonical-hash 14 v-payload)
                                        1 14 v-payload)
        o-upsert (pg/t:upsert -/TransactionReceipt
                               {:receipt-root v-root :transaction-root i-transaction-root
                                :status i-status :result-root i-result-root
                                :previous-state-root i-previous-state-root
                                :state-root i-state-root :cost-used i-cost-used
                                :error-code i-error-code})]
    (return v-root)))

(defn.pg transaction-receipt-get
  "Returns a receipt projection by its immutable canonical root."
  {:added "0.2"}
  [:bytea i-receipt-root]
  (let [o-row (pg/t:get -/TransactionReceipt
                        {:where {:receipt-root i-receipt-root}})]
    (return o-row)))

(defn.pg ^{:- [:bytea]} transaction-execute
  "Executes one validated transaction using an explicit context and state root.

   Expected language errors produce a receipt with the prior state root; this
   non-economic v1 policy does not advance sequence on a failed execution."
  {:added "0.2"}
  [:bytea i-transaction-root :text i-network :bytea i-context-root
   :bytea i-previous-state-root]
  (let [o-tx (-/transaction-get i-transaction-root)
        _ (pg/assert [o-tx :is-not-null] [:ledger/missing-transaction])
        _ (pg/assert (-/transaction-valid i-transaction-root i-network
                                          i-previous-state-root)
                     [:ledger/invalid-transaction])
        o-result (protocol-runtime/protocol-execute
                  i-context-root (:bytea (:->> o-tx "op_root")))
        (:text v-status) (:text (:->> o-result "status"))
        (:bytea v-result-root) (:bytea (:->> o-result "value_root"))
        (:bigint v-cost-used) (:bigint (:->> o-result "cost_used"))
        o-result-context (context/context-get (:bytea (:->> o-result "context_root")))
        (:bytea v-execution-state)
        (:bytea (:->> o-result-context "state_root"))
        (:bytea v-state-root)
        (pg/case (== v-status "ok")
                 (state/state-advance-account-sequence
                  v-execution-state (:bytea (:->> o-tx "origin"))
                  (:bigint (:->> o-result-context "block_height")))
                 :else i-previous-state-root)]
    (return (-/transaction-receipt-put
             i-transaction-root v-status v-result-root
             i-previous-state-root v-state-root v-cost-used nil))))

(defn.pg ^{:- [:bytea]} transaction-execute-signed
  "Executes only a transaction whose controller signature verifies against the
   supplied immutable predecessor state.  This is the public-admission entry
   point; transaction-execute remains available for deterministic internal
   fixtures and explicitly unsigned developer tooling."
  {:added "0.4"}
  [:bytea i-transaction-root :text i-network :bytea i-context-root
   :bytea i-previous-state-root]
  (let [_ (pg/assert (-/transaction-signed-valid
                      i-transaction-root i-network i-previous-state-root)
                     [:ledger/invalid-transaction-signature])]
    (return (-/transaction-execute
             i-transaction-root i-network i-context-root i-previous-state-root))))
