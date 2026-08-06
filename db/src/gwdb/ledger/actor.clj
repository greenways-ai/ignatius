(ns gwdb.ledger.actor
  (:require [tahto.core :as l]
            [postgres.core :as pg]
            [gwdb.ledger.account :as account]
            [gwdb.ledger.cell :as cell]
            [gwdb.ledger.codec :as codec]
            [gwdb.ledger.context :as context]
            [gwdb.ledger.function :as function]
            [gwdb.ledger.op :as op]
            [gwdb.ledger.state :as state]
            [gwdb.ledger.value :as value]))

(l/script :postgres
  {:require [[postgres.core :as pg]
             [gwdb.ledger.account :as account]
             [gwdb.ledger.cell :as cell]
             [gwdb.ledger.codec :as codec]
             [gwdb.ledger.context :as context]
             [gwdb.ledger.function :as function]
             [gwdb.ledger.op :as op]
             [gwdb.ledger.state :as state]
             [gwdb.ledger.value :as value]]
   :config {:dbname "gw-ledger-test"}
   :static {:application ["gw"]
            :all {:schema ["gw_ledger"]}}})

(defn.pg ^{:- [:text]}
  root-hex
  {:added "0.8"}
  [:bytea i-root]
  (return
   (pg/case [i-root :is-null] "-"
            :else (pg/encode i-root "hex"))))

(defn.pg ^{:- [:text]}
  special-name
  "Reads the symbolic actor instruction encoded by a special operation."
  {:added "0.8"}
  [:bytea i-op-root]
  (let [o-op (op/op-get i-op-root)
        o-symbol (cell/cell-by-hash (:bytea (:->> o-op "symbol_root")))]
    (return
     (pg/case (or [o-op :is-null] [o-symbol :is-null])
              ""
              :else
              (pg/encode (:bytea (:->> o-symbol "payload")) "escape")))))

(defn.pg ^{:- [:bytea]}
  actor-address-payload
  "Derives one deterministic actor address from transaction, caller and deploy site."
  {:added "0.8"}
  [:bytea i-context-root :bytea i-op-root]
  (let [o-context (context/context-get i-context-root)]
    (return
     (pg/decode
      (|| "R:actor-address:1:4:"
          (-/root-hex (:bytea (:->> o-context "transaction_root"))) ":"
          (-/root-hex (:bytea (:->> o-context "address"))) ":"
          (-/root-hex i-op-root) ":"
          (:text (:bigint (:->> o-context "cost_used"))))
      "escape"))))

(defn.pg ^{:- [:bytea]}
  actor-address-root
  "Returns the canonical address value for one deterministic deployment."
  {:added "0.8"}
  [:bytea i-context-root :bytea i-op-root]
  (return
   (value/put-blob
    (codec/canonical-hash
     14 (-/actor-address-payload i-context-root i-op-root)))))

(defn.pg ^{:- [:bytea]}
  callable-metadata
  "Canonical metadata attached to public actor methods."
  {:added "0.8"}
  []
  (return
   (value/map-assoc
    (value/put-map (pg/jsonb-build-array))
    (value/put-keyword "callable")
    (value/put-boolean true))))

(defn.pg ^{:- [:boolean]}
  definition-callable
  {:added "0.8"}
  [:bytea i-account-root :bytea i-symbol-root]
  (let [(:bytea v-metadata-root)
        (account/account-value-definition-metadata
         i-account-root i-symbol-root)
        o-metadata (cell/cell-by-hash v-metadata-root)
        (:bytea v-callable-root)
        (pg/case (or [o-metadata :is-null]
                     (not (== (:smallint (:->> o-metadata "type_tag")) 11)))
                 nil
                 :else
                 (value/map-get
                  v-metadata-root (value/put-keyword "callable")))]
    (return (== v-callable-root (value/put-boolean true)))))

(defn.pg ^{:- [:bytea]}
  callable-function-root
  "Resolves a callable function in a target account at one immutable state root."
  {:added "0.8"}
  [:bytea i-state-root :bytea i-address-root :bytea i-symbol-root]
  (let [(:bytea v-account-root)
        (state/state-account-root i-state-root i-address-root)
        (:bytea v-function-root)
        (pg/case [v-account-root :is-null]
                 nil
                 :else
                 (account/account-value-lookup
                  v-account-root i-symbol-root))]
    (return
     (pg/case (and [v-account-root :is-not-null]
                   (-/definition-callable v-account-root i-symbol-root)
                   (function/function-valid v-function-root))
              v-function-root
              :else nil))))

(defn.pg ^{:- [:bytea]}
  context-enter
  "Enters a target account while retaining origin, transaction, clock and cost."
  {:added "0.8"}
  [:bytea i-context-root :bytea i-state-root
   :bytea i-address-root :bytea i-caller-root]
  (let [o-context (context/context-get i-context-root)]
    (return
     (context/context-create
      i-state-root
      (:bytea (:->> o-context "origin"))
      i-address-root
      i-caller-root
      (:bytea (:->> o-context "transaction_root"))
      (:bigint (:->> o-context "block_height"))
      (:bigint (:->> o-context "timestamp"))
      (value/put-vector (pg/jsonb-build-array))
      (:bigint (:->> o-context "cost_used"))
      (:bigint (:->> o-context "cost_limit"))
      (+ (:integer (:->> o-context "depth")) 1)))))

(defn.pg ^{:- [:bytea]}
  context-restore
  "Restores caller address/locals/depth while retaining inner cost and chosen state."
  {:added "0.8"}
  [:bytea i-outer-context-root :bytea i-inner-context-root
   :bytea i-state-root]
  (let [o-outer (context/context-get i-outer-context-root)
        o-inner (context/context-get i-inner-context-root)]
    (return
     (context/context-create
      i-state-root
      (:bytea (:->> o-outer "origin"))
      (:bytea (:->> o-outer "address"))
      (:bytea (:->> o-outer "caller"))
      (:bytea (:->> o-outer "transaction_root"))
      (:bigint (:->> o-outer "block_height"))
      (:bigint (:->> o-outer "timestamp"))
      (:bytea (:->> o-outer "locals_root"))
      (:bigint (:->> o-inner "cost_used"))
      (:bigint (:->> o-outer "cost_limit"))
      (:integer (:->> o-outer "depth"))))))

(defn.pg ^{:- [:bytea]}
  deploy-state
  "Adds one keyless actor account controlled and parented by the active account."
  {:added "0.8"}
  [:bytea i-context-root :bytea i-actor-address-root]
  (let [o-context (context/context-get i-context-root)
        (:bytea v-state-root) (:bytea (:->> o-context "state_root"))
        (:bytea v-controller-root) (:bytea (:->> o-context "address"))
        (:bytea v-existing)
        (state/state-account-root v-state-root i-actor-address-root)
        _ (pg/assert [v-existing :is-null] [:ledger/actor-address-exists])
        (:bytea v-account-root)
        (account/account-value-create-actor
         v-controller-root v-controller-root)]
    (return
     (state/state-assoc-account
      v-state-root i-actor-address-root v-account-root
      (:bigint (:->> o-context "block_height"))))))

(defn.pg ^{:- [:bytea]}
  deploy-op
  "Builds a special operation that creates an actor then executes its initializer."
  {:added "0.8"}
  [:bytea i-initializer-op-root]
  (return
   (op/put-op
    "special" nil (value/put-symbol "actor/deploy")
    nil nil nil nil nil
    (pg/jsonb-build-array
     (pg/encode i-initializer-op-root "hex")))))

(defn.pg ^{:- [:bytea]}
  actor-call-op
  "Builds a stateful actor call. Child zero is the target; remaining children are args."
  {:added "0.8"}
  [:bytea i-target-op-root :bytea i-method-symbol-root :jsonb i-argument-op-roots]
  (return
   (op/put-op
    "special" i-method-symbol-root (value/put-symbol "actor/call")
    nil nil nil nil nil
    (|| (pg/jsonb-build-array
         (pg/encode i-target-op-root "hex"))
        i-argument-op-roots))))

(defn.pg ^{:- [:bytea]}
  actor-query-op
  "Builds a read-only actor call whose callee state is discarded on return."
  {:added "0.8"}
  [:bytea i-target-op-root :bytea i-method-symbol-root :jsonb i-argument-op-roots]
  (return
   (op/put-op
    "special" i-method-symbol-root (value/put-symbol "actor/query")
    nil nil nil nil nil
    (|| (pg/jsonb-build-array
         (pg/encode i-target-op-root "hex"))
        i-argument-op-roots))))