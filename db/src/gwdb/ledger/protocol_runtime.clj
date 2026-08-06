(ns gwdb.ledger.protocol-runtime
  (:require [tahto.core :as l]
            [postgres.core :as pg]
            [gwdb.ledger.cell :as cell]
            [gwdb.ledger.context :as context]
            [gwdb.ledger.function :as function]
            [gwdb.ledger.op :as op]
            [gwdb.ledger.primitive :as primitive]
            [gwdb.ledger.protocol :as protocol]
            [gwdb.ledger.runtime-v2 :as runtime-v2]
            [gwdb.ledger.value :as value]))

(l/script :postgres
  {:require [[postgres.core :as pg]
             [gwdb.ledger.cell :as cell]
             [gwdb.ledger.context :as context]
             [gwdb.ledger.function :as function]
             [gwdb.ledger.op :as op]
             [gwdb.ledger.primitive :as primitive]
             [gwdb.ledger.protocol :as protocol]
             [gwdb.ledger.runtime-v2 :as runtime-v2]
             [gwdb.ledger.value :as value]]
   :config {:dbname "gw-ledger-test"}
   :static {:application ["gw"]
            :all {:schema ["gw_ledger"]}}})

(defn.pg ^{:- [:jsonb]}
  arguments-ok
  {:added "0.5"}
  [:bytea i-context-root :jsonb i-roots]
  (let [o-context (context/context-get i-context-root)]
    (return {:status "ok"
             :context-root i-context-root
             :roots i-roots
             :cost-used (:bigint (:->> o-context "cost_used"))})))

(defn.pg ^{:- [:jsonb]}
  evaluate-arguments-at
  "Evaluates ordinary committed argument operations left-to-right."
  {:added "0.5"}
  [:bytea i-context-root :bytea i-op-root :integer i-position
   :integer i-count :jsonb i-roots]
  (cond (>= i-position i-count)
        (return (-/arguments-ok i-context-root i-roots))
        :else
        (let [(:bytea v-child-root) (op/op-child-root i-op-root i-position)
              o-result (runtime-v2/execute i-context-root v-child-root)]
          (cond (== (:text (:->> o-result "status")) "error")
                (return o-result)
                :else
                (let [(:jsonb v-next-roots)
                      (|| i-roots
                          (pg/jsonb-build-array
                           (pg/encode
                            (:bytea (:->> o-result "value_root")) "hex")))]
                  (return (-/evaluate-arguments-at
                           (:bytea (:->> o-result "context_root"))
                           i-op-root (+ i-position 1) i-count v-next-roots)))))))

(defn.pg ^{:- [:jsonb]}
  evaluate-arguments
  {:added "0.5"}
  [:bytea i-context-root :bytea i-op-root]
  (return (-/evaluate-arguments-at
           i-context-root i-op-root 0
           (cell/cell-ref-count i-op-root "op-child")
           (pg/jsonb-build-array))))

(defn.pg ^{:- [:bytea]}
  argument-root
  {:added "0.5"}
  [:jsonb i-roots :integer i-position]
  (return (pg/decode (:text (:->> i-roots i-position)) "hex")))

(defn.pg ^{:- [:jsonb]}
  copy-argument-tail-at
  {:added "0.5"}
  [:jsonb i-roots :integer i-position :integer i-count :jsonb i-out]
  (cond (>= i-position i-count)
        (return i-out)
        :else
        (return (-/copy-argument-tail-at
                 i-roots (+ i-position 1) i-count
                 (|| i-out
                     (pg/jsonb-build-array (:text (:->> i-roots i-position))))))))

(defn.pg ^{:- [:jsonb]}
  execute-protocol-define
  {:added "0.5"}
  [:bytea i-context-root :bytea i-op-root]
  (let [(:integer v-count) (cell/cell-ref-count i-op-root "op-child")
        _ (when (not (== v-count 2))
            (return (protocol/result-error i-context-root "protocol/define-arity")))
        o-arguments (-/evaluate-arguments i-context-root i-op-root)
        _ (when (== (:text (:->> o-arguments "status")) "error")
            (return o-arguments))
        (:jsonb v-roots) (:jsonb (:->> o-arguments "roots"))]
    (return
     (protocol/define-transition
      (:bytea (:->> o-arguments "context_root"))
      (-/argument-root v-roots 0)
      (-/argument-root v-roots 1)))))

(defn.pg ^{:- [:jsonb]}
  execute-protocol-extend
  {:added "0.5"}
  [:bytea i-context-root :bytea i-op-root]
  (let [(:integer v-count) (cell/cell-ref-count i-op-root "op-child")
        _ (when (not (== v-count 3))
            (return (protocol/result-error i-context-root "protocol/extend-arity")))
        o-arguments (-/evaluate-arguments i-context-root i-op-root)
        _ (when (== (:text (:->> o-arguments "status")) "error")
            (return o-arguments))
        (:jsonb v-roots) (:jsonb (:->> o-arguments "roots"))]
    (return
     (protocol/extend-transition
      (:bytea (:->> o-arguments "context_root"))
      (-/argument-root v-roots 0)
      (-/argument-root v-roots 1)
      (-/argument-root v-roots 2)))))

(defn.pg ^{:- [:jsonb]}
  execute-protocol-invoke
  "Resolves a method against immutable state and executes its committed body."
  {:added "0.5"}
  [:bytea i-context-root :bytea i-op-root]
  (let [(:integer v-count) (cell/cell-ref-count i-op-root "op-child")
        _ (when (< v-count 3)
            (return (protocol/result-error i-context-root "protocol/invoke-arity")))
        o-arguments (-/evaluate-arguments i-context-root i-op-root)
        _ (when (== (:text (:->> o-arguments "status")) "error")
            (return o-arguments))
        (:jsonb v-roots) (:jsonb (:->> o-arguments "roots"))
        (:bytea v-argument-context-root)
        (:bytea (:->> o-arguments "context_root"))
        o-context (context/context-get v-argument-context-root)
        (:bytea v-protocol-root) (-/argument-root v-roots 0)
        (:bytea v-method-name-root) (-/argument-root v-roots 1)
        (:bytea v-receiver-root) (-/argument-root v-roots 2)
        (:bigint v-declared-arity)
        (protocol/method-arity v-protocol-root v-method-name-root)
        (:integer v-call-arity) (- v-count 2)
        _ (when (not (== v-declared-arity v-call-arity))
            (return (protocol/result-error
                     v-argument-context-root "protocol/method-arity")))
        (:bytea v-function-root)
        (protocol/resolve-method
         (:bytea (:->> o-context "state_root"))
         (:bytea (:->> o-context "address"))
         v-protocol-root v-method-name-root v-receiver-root)
        o-function (function/function-get v-function-root)
        _ (when (or [v-function-root :is-null]
                    [o-function :is-null]
                    (not (function/function-valid v-function-root)))
            (return (protocol/result-error
                     v-argument-context-root "missing-protocol-implementation")))
        (:integer v-parameter-count)
        (cell/cell-ref-count
         (:bytea (:->> o-function "parameters_root")) "element")
        _ (when (not (== v-parameter-count v-call-arity))
            (return (protocol/result-error
                     v-argument-context-root "protocol/function-arity")))
        _ (when (not (context/context-can-charge v-argument-context-root 3))
            (return (protocol/result-error v-argument-context-root "cost-limit")))
        (:jsonb v-local-roots)
        (-/copy-argument-tail-at
         v-roots 2 v-count (pg/jsonb-build-array))
        (:bytea v-locals-root) (value/put-vector v-local-roots)
        (:bytea v-function-context)
        (context/context-with-locals
         v-argument-context-root v-locals-root
         (+ (:integer (:->> o-context "depth")) 1))
        (:bytea v-call-context) (context/context-charge v-function-context 3)]
    (return (runtime-v2/execute
             v-call-context (:bytea (:->> o-function "body_root"))))))

(defn.pg ^{:- [:jsonb]}
  protocol-execute
  "Executes one signed top-level operation, intercepting closed protocol intrinsics."
  {:added "0.7"}
  [:bytea i-context-root :bytea i-op-root]
  (let [o-op (op/op-get i-op-root)
        (:text v-kind)
        (pg/case [o-op :is-null] ""
                 :else (:text (:->> o-op "op_kind")))
        o-primitive
        (pg/case (== v-kind "invoke")
                 (primitive/primitive-get-root
                  (:bytea (:->> o-op "function_root")))
                 :else nil)
        (:text v-primitive-id)
        (pg/case [o-primitive :is-null] ""
                 :else (:text (:->> o-primitive "primitive_id")))]
    (cond (== v-primitive-id "protocol/define")
          (return (-/execute-protocol-define i-context-root i-op-root))
          (== v-primitive-id "protocol/extend")
          (return (-/execute-protocol-extend i-context-root i-op-root))
          (== v-primitive-id "protocol/invoke")
          (return (-/execute-protocol-invoke i-context-root i-op-root))
          :else
          (return (runtime-v2/execute i-context-root i-op-root)))))