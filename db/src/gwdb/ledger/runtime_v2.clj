(ns gwdb.ledger.runtime-v2
  (:require [tahto.core :as l]
            [postgres.core :as pg]
            [gwdb.ledger.cell :as cell]
            [gwdb.ledger.context :as context]
            [gwdb.ledger.function :as function]
            [gwdb.ledger.op :as op]
            [gwdb.ledger.primitive :as primitive]
            [gwdb.ledger.protocol :as protocol]
            [gwdb.ledger.runtime :as runtime]
            [gwdb.ledger.runtime-support :as support]
            [gwdb.ledger.state :as state]
            [gwdb.ledger.account :as account]
            [gwdb.ledger.value :as value]))

(l/script :postgres
  {:require [[postgres.core :as pg]
             [gwdb.ledger.cell :as cell]
             [gwdb.ledger.context :as context]
             [gwdb.ledger.function :as function]
             [gwdb.ledger.op :as op]
             [gwdb.ledger.primitive :as primitive]
             [gwdb.ledger.protocol :as protocol]
             [gwdb.ledger.runtime :as runtime]
             [gwdb.ledger.runtime-support :as support]
             [gwdb.ledger.state :as state]
             [gwdb.ledger.account :as account]
             [gwdb.ledger.value :as value]]
   :config {:dbname "gw-ledger-test"}
   :static {:application ["gw"]
            :all {:schema ["gw_ledger"]}}})

(defn.pg ^{:- [:jsonb]}
  execute-machine
  "Single self-recursive evaluator for operations, child ranges, calls and conditions."
  {:added "0.7"}
  [:text i-mode :bytea i-context-root :bytea i-op-root
   :integer i-position :integer i-count :jsonb i-roots
   :bytea i-callable-root]
  (cond
    (== i-mode "children")
    (cond (>= i-position i-count)
          (return (support/evaluated-roots i-context-root i-roots))
          :else
          (let [o-child (-/execute-machine
                         "eval" i-context-root
                         (op/op-child-root i-op-root i-position)
                         0 0 (pg/jsonb-build-array) nil)
                _ (when (== (:text (:->> o-child "status")) "error")
                    (return o-child))
                (:jsonb v-next)
                (|| i-roots
                    (pg/jsonb-build-array
                     (pg/encode (:bytea (:->> o-child "value_root")) "hex")))]
            (return (-/execute-machine
                     "children" (:bytea (:->> o-child "context_root"))
                     i-op-root (+ i-position 1) i-count v-next nil))))

    (== i-mode "condition")
    (cond (>= i-position i-count)
          (return (runtime/result-ok i-context-root (value/put-nil)))
          :else
          (let [o-test (-/execute-machine
                        "eval" i-context-root
                        (op/op-child-root i-op-root i-position)
                        0 0 (pg/jsonb-build-array) nil)
                _ (when (== (:text (:->> o-test "status")) "error")
                    (return o-test))]
            (cond (support/truthy (:bytea (:->> o-test "value_root")))
                  (return (-/execute-machine
                           "eval" (:bytea (:->> o-test "context_root"))
                           (op/op-child-root i-op-root (+ i-position 1))
                           0 0 (pg/jsonb-build-array) nil))
                  :else
                  (return (-/execute-machine
                           "condition" (:bytea (:->> o-test "context_root"))
                           i-op-root (+ i-position 2) i-count
                           (pg/jsonb-build-array) nil)))))

    (== i-mode "call")
    (let [o-primitive (primitive/primitive-get-root i-callable-root)
          o-function (function/function-get i-callable-root)
          (:integer v-count) (pg/jsonb-array-length i-roots)]
      (cond [o-primitive :is-not-null]
            (let [(:integer v-arity) (:integer (:->> o-primitive "arity"))
                  (:text v-id) (:text (:->> o-primitive "primitive_id"))
                  _ (when (and (not (== v-arity -1))
                               (not (== v-arity v-count)))
                      (return (runtime/result-error i-context-root "arity")))]
              (cond (== v-id "protocol/define")
                    (return (protocol/define-transition
                             i-context-root
                             (support/root-at i-roots 0)
                             (support/root-at i-roots 1)))

                    (== v-id "protocol/extend")
                    (return (protocol/extend-transition
                             i-context-root
                             (support/root-at i-roots 0)
                             (support/root-at i-roots 1)
                             (support/root-at i-roots 2)))

                    (== v-id "protocol/invoke")
                    (let [(:bytea v-protocol-root) (support/root-at i-roots 0)
                          (:bytea v-method-root) (support/root-at i-roots 1)
                          (:jsonb v-arguments)
                          (support/roots-tail-at
                           i-roots 2 v-count (pg/jsonb-build-array))
                          (:integer v-argument-count)
                          (pg/jsonb-array-length v-arguments)
                          _ (when (not (== (protocol/method-arity
                                           v-protocol-root v-method-root)
                                          v-argument-count))
                              (return (runtime/result-error
                                       i-context-root "protocol/method-arity")))
                          o-context (context/context-get i-context-root)
                          (:bytea v-function-root)
                          (protocol/resolve-method
                           (:bytea (:->> o-context "state_root"))
                           (:bytea (:->> o-context "address"))
                           v-protocol-root v-method-root
                           (support/root-at v-arguments 0))]
                      (cond [v-function-root :is-null]
                            (return (runtime/result-error
                                     i-context-root
                                     "missing-protocol-implementation"))
                            :else
                            (return (-/execute-machine
                                     "call" i-context-root nil 0 0
                                     v-arguments v-function-root))))

                    :else
                    (return (support/apply-primitive
                             i-context-root v-id i-roots))))

            [o-function :is-not-null]
            (let [o-caller (context/context-get i-context-root)
                  _ (when (not (function/function-valid i-callable-root))
                      (return (runtime/result-error
                               i-context-root "invalid-function")))
                  (:integer v-parameter-count)
                  (cell/cell-ref-count
                   (:bytea (:->> o-function "parameters_root")) "element")
                  _ (when (not (== v-parameter-count v-count))
                      (return (runtime/result-error i-context-root "arity")))
                  _ (when (>= (:integer (:->> o-caller "depth")) 64)
                      (return (runtime/result-error i-context-root "max-depth")))
                  _ (when (not (context/context-can-charge i-context-root 2))
                      (return (runtime/result-error i-context-root "cost-limit")))
                  (:bytea v-frame-root)
                  (value/put-vector
                   (|| i-roots
                       (support/vector-roots
                        (:bytea (:->> o-function "closure_root")))))
                  (:bytea v-call-context)
                  (context/context-charge
                   (context/context-with-locals
                    i-context-root v-frame-root
                    (+ (:integer (:->> o-caller "depth")) 1))
                   2)
                  o-body (-/execute-machine
                          "eval" v-call-context
                          (:bytea (:->> o-function "body_root"))
                          0 0 (pg/jsonb-build-array) nil)
                  _ (when (== (:text (:->> o-body "status")) "error")
                      (return o-body))
                  (:bytea v-restored)
                  (context/context-with-locals
                   (:bytea (:->> o-body "context_root"))
                   (:bytea (:->> o-caller "locals_root"))
                   (:integer (:->> o-caller "depth")))]
              (return (runtime/result-ok
                       v-restored (:bytea (:->> o-body "value_root")))))

            :else
            (return (runtime/result-error i-context-root "unknown-callable"))))

    :else
    (let [o-op (op/op-get i-op-root)
          (:text v-kind)
          (pg/case [o-op :is-null] ""
                   :else (:text (:->> o-op "op_kind")))]
      (cond [o-op :is-null]
            (return (runtime/result-error i-context-root "unknown-op"))

            (not (op/op-valid i-op-root))
            (return (runtime/result-error i-context-root "invalid-op"))

            (== v-kind "constant")
            (return (runtime/execute-constant i-context-root i-op-root))

            (== v-kind "special")
            (return (runtime/execute-special i-context-root i-op-root))

            (== v-kind "lookup")
            (return (runtime/execute-lookup i-context-root i-op-root))

            (== v-kind "local")
            (return (runtime/execute-local i-context-root i-op-root))

            (== v-kind "lambda")
            (return (runtime/execute-lambda i-context-root i-op-root))

            (== v-kind "invoke")
            (let [(:bytea v-static-root) (:bytea (:->> o-op "function_root"))
                  (:integer v-child-count)
                  (cell/cell-ref-count i-op-root "op-child")]
              (cond [v-static-root :is-not-null]
                    (let [o-arguments (-/execute-machine
                                       "children" i-context-root i-op-root
                                       0 v-child-count
                                       (pg/jsonb-build-array) nil)
                          _ (when (== (:text (:->> o-arguments "status")) "error")
                              (return o-arguments))]
                      (return (-/execute-machine
                               "call" (:bytea (:->> o-arguments "context_root"))
                               nil 0 0 (:jsonb (:->> o-arguments "roots"))
                               v-static-root)))

                    (< v-child-count 1)
                    (return (runtime/result-error
                             i-context-root "call-requires-callee"))

                    :else
                    (let [o-callee (-/execute-machine
                                    "eval" i-context-root
                                    (op/op-child-root i-op-root 0)
                                    0 0 (pg/jsonb-build-array) nil)
                          _ (when (== (:text (:->> o-callee "status")) "error")
                              (return o-callee))
                          o-arguments (-/execute-machine
                                       "children"
                                       (:bytea (:->> o-callee "context_root"))
                                       i-op-root 1 v-child-count
                                       (pg/jsonb-build-array) nil)
                          _ (when (== (:text (:->> o-arguments "status")) "error")
                              (return o-arguments))]
                      (return (-/execute-machine
                               "call" (:bytea (:->> o-arguments "context_root"))
                               nil 0 0 (:jsonb (:->> o-arguments "roots"))
                               (:bytea (:->> o-callee "value_root")))))))

            (== v-kind "let")
            (let [_ (when (not (== (cell/cell-ref-count
                                    i-op-root "op-child") 2))
                      (return (runtime/result-error i-context-root "let-arity")))
                  o-binding (-/execute-machine
                             "eval" i-context-root
                             (op/op-child-root i-op-root 0)
                             0 0 (pg/jsonb-build-array) nil)
                  _ (when (== (:text (:->> o-binding "status")) "error")
                      (return o-binding))
                  (:bytea v-binding-context-root)
                  (:bytea (:->> o-binding "context_root"))
                  o-binding-context (context/context-get v-binding-context-root)
                  (:bytea v-frame-root)
                  (value/put-vector
                   (|| (support/vector-roots
                        (:bytea (:->> o-binding-context "locals_root")))
                       (pg/jsonb-build-array
                        (pg/encode
                         (:bytea (:->> o-binding "value_root")) "hex"))))
                  _ (when (not (context/context-can-charge
                                v-binding-context-root 1))
                      (return (runtime/result-error
                               v-binding-context-root "cost-limit")))
                  (:bytea v-body-context)
                  (context/context-charge
                   (context/context-with-locals
                    v-binding-context-root v-frame-root
                    (+ (:integer (:->> o-binding-context "depth")) 1))
                   1)
                  o-body (-/execute-machine
                          "eval" v-body-context
                          (op/op-child-root i-op-root 1)
                          0 0 (pg/jsonb-build-array) nil)
                  _ (when (== (:text (:->> o-body "status")) "error")
                      (return o-body))
                  (:bytea v-restored)
                  (context/context-with-locals
                   (:bytea (:->> o-body "context_root"))
                   (:bytea (:->> o-binding-context "locals_root"))
                   (:integer (:->> o-binding-context "depth")))]
              (return (runtime/result-ok
                       v-restored (:bytea (:->> o-body "value_root")))))

            (== v-kind "def")
            (let [_ (when (not (== (cell/cell-ref-count
                                    i-op-root "op-child") 1))
                      (return (runtime/result-error i-context-root "def-arity")))
                  o-value (-/execute-machine
                           "eval" i-context-root
                           (op/op-child-root i-op-root 0)
                           0 0 (pg/jsonb-build-array) nil)
                  _ (when (== (:text (:->> o-value "status")) "error")
                      (return o-value))
                  (:bytea v-value-context-root)
                  (:bytea (:->> o-value "context_root"))
                  o-value-context (context/context-get v-value-context-root)
                  _ (when (not (context/context-can-charge
                                v-value-context-root 2))
                      (return (runtime/result-error
                               v-value-context-root "cost-limit")))
                  (:bytea v-account-root)
                  (state/state-account-root
                   (:bytea (:->> o-value-context "state_root"))
                   (:bytea (:->> o-value-context "address")))
                  _ (when [v-account-root :is-null]
                      (return (runtime/result-error
                               v-value-context-root "missing-account")))
                  (:bytea v-next-account)
                  (account/account-value-define
                   v-account-root (:bytea (:->> o-op "symbol_root"))
                   (:bytea (:->> o-value "value_root")))
                  (:bytea v-next-state)
                  (state/state-assoc-account
                   (:bytea (:->> o-value-context "state_root"))
                   (:bytea (:->> o-value-context "address"))
                   v-next-account
                   (:bigint (:->> o-value-context "block_height")))
                  (:bytea v-next-context)
                  (context/context-charge
                   (context/context-with-state
                    v-value-context-root v-next-state) 2)]
              (return (runtime/result-ok
                       v-next-context (:bytea (:->> o-value "value_root")))))

            (== v-kind "cond")
            (let [(:integer v-count)
                  (cell/cell-ref-count i-op-root "op-child")]
              (cond (not (== (pg/mod v-count 2) 0))
                    (return (runtime/result-error
                             i-context-root "uneven-condition-children"))
                    :else
                    (return (-/execute-machine
                             "condition" i-context-root i-op-root
                             0 v-count (pg/jsonb-build-array) nil))))

            (== v-kind "do")
            (let [(:integer v-count)
                  (cell/cell-ref-count i-op-root "op-child")]
              (cond (== v-count 0)
                    (return (runtime/result-ok
                             i-context-root (value/put-nil)))
                    :else
                    (let [o-results (-/execute-machine
                                     "children" i-context-root i-op-root
                                     0 v-count (pg/jsonb-build-array) nil)
                          _ (when (== (:text (:->> o-results "status")) "error")
                              (return o-results))]
                      (return (runtime/result-ok
                               (:bytea (:->> o-results "context_root"))
                               (support/root-at
                                (:jsonb (:->> o-results "roots"))
                                (- v-count 1)))))))

            :else
            (return (runtime/result-error i-context-root "unsupported-op"))))))

(defn.pg ^{:- [:jsonb]}
  execute
  "Public recursive deterministic evaluator used by signed transactions."
  {:added "0.7"}
  [:bytea i-context-root :bytea i-op-root]
  (return (-/execute-machine
           "eval" i-context-root i-op-root 0 0
           (pg/jsonb-build-array) nil)))