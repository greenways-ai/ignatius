(ns gwdb.ledger.actor-runtime
  (:require [tahto.core :as l]
            [postgres.core :as pg]
            [gwdb.ledger.account :as account]
            [gwdb.ledger.actor :as actor]
            [gwdb.ledger.cell :as cell]
            [gwdb.ledger.context :as context]
            [gwdb.ledger.function :as function]
            [gwdb.ledger.op :as op]
            [gwdb.ledger.runtime :as runtime]
            [gwdb.ledger.runtime-support :as support]
            [gwdb.ledger.runtime-v2 :as runtime-v2]
            [gwdb.ledger.state :as state]
            [gwdb.ledger.value :as value]))

(l/script :postgres
  {:require [[postgres.core :as pg]
             [gwdb.ledger.account :as account]
             [gwdb.ledger.actor :as actor]
             [gwdb.ledger.cell :as cell]
             [gwdb.ledger.context :as context]
             [gwdb.ledger.function :as function]
             [gwdb.ledger.op :as op]
             [gwdb.ledger.runtime :as runtime]
             [gwdb.ledger.runtime-support :as support]
             [gwdb.ledger.runtime-v2 :as runtime-v2]
             [gwdb.ledger.state :as state]
             [gwdb.ledger.value :as value]]
   :config {:dbname "gw-ledger-test"}
   :static {:application ["gw"]
            :all {:schema ["gw_ledger"]}}})

(defn.pg ^{:- [:boolean]}
  actor-special
  {:added "0.8"}
  [:bytea i-op-root]
  (let [(:text v-special) (actor/special-name i-op-root)]
    (return
     (or (== v-special "actor/deploy")
         (== v-special "actor/call")
         (== v-special "actor/query")))))

(defn.pg ^{:- [:jsonb]}
  evaluated-roots
  {:added "0.8"}
  [:bytea i-context-root :jsonb i-roots]
  (let [o-context (context/context-get i-context-root)]
    (return {:status "ok"
             :context-root i-context-root
             :roots i-roots
             :cost-used (:bigint (:->> o-context "cost_used"))})))

(defn.pg ^{:- [:jsonb]}
  evaluate-children-at
  "Evaluates one actor operation child range left-to-right."
  {:added "0.8"}
  [:bytea i-context-root :bytea i-op-root
   :integer i-position :integer i-count :jsonb i-roots]
  (cond (>= i-position i-count)
        (return (-/evaluated-roots i-context-root i-roots))
        :else
        (let [o-result
              (runtime-v2/execute
               i-context-root
               (op/op-child-root i-op-root i-position))
              _ (when (== (:text (:->> o-result "status")) "error")
                  (return o-result))
              (:jsonb v-next-roots)
              (|| i-roots
                  (pg/jsonb-build-array
                   (pg/encode
                    (:bytea (:->> o-result "value_root")) "hex")))]
          (return
           (-/evaluate-children-at
            (:bytea (:->> o-result "context_root"))
            i-op-root (+ i-position 1) i-count v-next-roots)))))

(defn.pg ^{:- [:boolean]}
  callables-valid-at
  {:added "0.8"}
  [:bytea i-state-root :bytea i-address-root
   :bytea i-callables-root :integer i-position :integer i-count]
  (cond (>= i-position i-count)
        (return true)
        :else
        (let [(:bytea v-account-root)
              (state/state-account-root i-state-root i-address-root)
              (:bytea v-symbol-root)
              (value/vector-get i-callables-root i-position)
              (:bytea v-function-root)
              (pg/case [v-account-root :is-null] nil
                       :else
                       (account/account-value-lookup
                        v-account-root v-symbol-root))]
          (return
           (and [v-account-root :is-not-null]
                (== (cell/cell-type-tag v-symbol-root) 7)
                (function/function-valid v-function-root)
                (-/callables-valid-at
                 i-state-root i-address-root i-callables-root
                 (+ i-position 1) i-count))))))

(defn.pg ^{:- [:bytea]}
  mark-callables-at
  "Associates callable metadata with a deployed actor's public functions."
  {:added "0.8"}
  [:bytea i-state-root :bytea i-address-root
   :bytea i-callables-root :integer i-position :integer i-count
   :bigint i-block-height]
  (cond (>= i-position i-count)
        (return i-state-root)
        :else
        (let [(:bytea v-account-root)
              (state/state-account-root i-state-root i-address-root)
              (:bytea v-symbol-root)
              (value/vector-get i-callables-root i-position)
              (:bytea v-next-account)
              (account/account-value-set-definition-metadata
               v-account-root v-symbol-root (actor/callable-metadata))
              (:bytea v-next-state)
              (state/state-assoc-account
               i-state-root i-address-root v-next-account i-block-height)]
          (return
           (-/mark-callables-at
            v-next-state i-address-root i-callables-root
            (+ i-position 1) i-count i-block-height)))))

(defn.pg ^{:- [:jsonb]}
  execute-deploy
  {:added "0.8"}
  [:bytea i-context-root :bytea i-op-root]
  (let [o-op (op/op-get i-op-root)
        (:integer v-child-count)
        (cell/cell-ref-count i-op-root "op-child")
        _ (when (not (== v-child-count 1))
            (return
             (runtime/result-error
              i-context-root "actor/deploy-arity")))
        (:bytea v-callables-root)
        (:bytea (:->> o-op "value_root"))
        _ (when (not (== (cell/cell-type-tag v-callables-root) 10))
            (return
             (runtime/result-error
              i-context-root "actor/callables-vector-required")))
        _ (when (not (context/context-can-charge i-context-root 5))
            (return
             (runtime/result-error i-context-root "cost-limit")))
        o-caller (context/context-get i-context-root)
        (:bytea v-actor-address)
        (actor/actor-address-root i-context-root i-op-root)
        (:bytea v-charged-context)
        (context/context-charge i-context-root 5)
        (:bytea v-deploy-state)
        (actor/deploy-state v-charged-context v-actor-address)
        (:bytea v-actor-context)
        (actor/context-enter
         v-charged-context v-deploy-state v-actor-address
         (:bytea (:->> o-caller "address")))
        o-initialized
        (runtime-v2/execute
         v-actor-context (op/op-child-root i-op-root 0))
        _ (when (== (:text (:->> o-initialized "status")) "error")
            (return o-initialized))
        (:bytea v-initialized-context-root)
        (:bytea (:->> o-initialized "context_root"))
        o-initialized-context
        (context/context-get v-initialized-context-root)
        (:bytea v-initialized-state)
        (:bytea (:->> o-initialized-context "state_root"))
        (:integer v-callable-count)
        (cell/cell-ref-count v-callables-root "element")
        _ (when (not
                 (-/callables-valid-at
                  v-initialized-state v-actor-address v-callables-root
                  0 v-callable-count))
            (return
             (runtime/result-error
              v-initialized-context-root "actor/invalid-callable")))
        (:bytea v-marked-state)
        (-/mark-callables-at
         v-initialized-state v-actor-address v-callables-root
         0 v-callable-count
         (:bigint (:->> o-initialized-context "block_height")))
        (:bytea v-marked-context)
        (context/context-with-state
         v-initialized-context-root v-marked-state)
        (:bytea v-restored)
        (actor/context-restore
         v-charged-context v-marked-context v-marked-state)]
    (return (runtime/result-ok v-restored v-actor-address))))

(defn.pg ^{:- [:jsonb]}
  execute-call
  {:added "0.8"}
  [:bytea i-context-root :bytea i-op-root :boolean i-query]
  (let [o-op (op/op-get i-op-root)
        (:integer v-child-count)
        (cell/cell-ref-count i-op-root "op-child")
        _ (when (< v-child-count 1)
            (return
             (runtime/result-error
              i-context-root "actor/call-requires-target")))
        o-target
        (runtime-v2/execute
         i-context-root (op/op-child-root i-op-root 0))
        _ (when (== (:text (:->> o-target "status")) "error")
            (return o-target))
        (:bytea v-target-root)
        (:bytea (:->> o-target "value_root"))
        o-arguments
        (-/evaluate-children-at
         (:bytea (:->> o-target "context_root"))
         i-op-root 1 v-child-count (pg/jsonb-build-array))
        _ (when (== (:text (:->> o-arguments "status")) "error")
            (return o-arguments))
        (:bytea v-argument-context-root)
        (:bytea (:->> o-arguments "context_root"))
        o-argument-context
        (context/context-get v-argument-context-root)
        (:bytea v-method-root)
        (:bytea (:->> o-op "value_root"))
        (:bytea v-function-root)
        (actor/callable-function-root
         (:bytea (:->> o-argument-context "state_root"))
         v-target-root v-method-root)
        o-function (function/function-get v-function-root)
        _ (when (or [v-function-root :is-null]
                    [o-function :is-null])
            (return
             (runtime/result-error
              v-argument-context-root "actor/not-callable")))
        (:jsonb v-argument-roots)
        (:jsonb (:->> o-arguments "roots"))
        (:integer v-argument-count)
        (pg/jsonb-array-length v-argument-roots)
        (:integer v-parameter-count)
        (cell/cell-ref-count
         (:bytea (:->> o-function "parameters_root")) "element")
        _ (when (not (== v-argument-count v-parameter-count))
            (return
             (runtime/result-error
              v-argument-context-root "actor/arity")))
        _ (when (not
                 (context/context-can-charge
                  v-argument-context-root 4))
            (return
             (runtime/result-error
              v-argument-context-root "cost-limit")))
        (:bytea v-charged-context)
        (context/context-charge v-argument-context-root 4)
        (:bytea v-entered-context)
        (actor/context-enter
         v-charged-context
         (:bytea (:->> o-argument-context "state_root"))
         v-target-root
         (:bytea (:->> o-argument-context "address")))
        o-entered-context (context/context-get v-entered-context)
        (:bytea v-frame-root)
        (value/put-vector
         (|| v-argument-roots
             (support/vector-roots
              (:bytea (:->> o-function "closure_root")))))
        (:bytea v-call-context)
        (context/context-with-locals
         v-entered-context v-frame-root
         (:integer (:->> o-entered-context "depth")))
        o-called
        (runtime-v2/execute
         v-call-context (:bytea (:->> o-function "body_root")))
        _ (when (== (:text (:->> o-called "status")) "error")
            (return o-called))
        (:bytea v-called-context-root)
        (:bytea (:->> o-called "context_root"))
        o-called-context (context/context-get v-called-context-root)
        (:bytea v-return-state)
        (pg/case i-query
                 (:bytea (:->> o-argument-context "state_root"))
                 :else
                 (:bytea (:->> o-called-context "state_root")))
        (:bytea v-restored)
        (actor/context-restore
         v-charged-context v-called-context-root v-return-state)]
    (return
     (runtime/result-ok
      v-restored (:bytea (:->> o-called "value_root"))))))

(defn.pg ^{:- [:jsonb]}
  execute
  "Executes a top-level actor deploy, stateful call or read-only query."
  {:added "0.8"}
  [:bytea i-context-root :bytea i-op-root]
  (let [(:text v-special) (actor/special-name i-op-root)]
    (cond (== v-special "actor/deploy")
          (return (-/execute-deploy i-context-root i-op-root))

          (== v-special "actor/call")
          (return (-/execute-call i-context-root i-op-root false))

          (== v-special "actor/query")
          (return (-/execute-call i-context-root i-op-root true))

          :else
          (return
           (runtime/result-error
            i-context-root "unknown-actor-operation")))))