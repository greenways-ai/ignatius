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
             [gwdb.ledger.state :as state]
             [gwdb.ledger.account :as account]
             [gwdb.ledger.value :as value]]
   :config {:dbname "gw-ledger-test"}
   :static {:application ["gw"]
            :all {:schema ["gw_ledger"]}}})

(declare execute)

(defn.pg ^{:- [:bytea]}
  root-at
  {:added "0.7"}
  [:jsonb i-roots :integer i-position]
  (return (pg/decode (:text (:->> i-roots i-position)) "hex")))

(defn.pg ^{:- [:jsonb]}
  roots-tail-at
  {:added "0.7"}
  [:jsonb i-roots :integer i-position :integer i-count :jsonb i-out]
  (cond (>= i-position i-count)
        (return i-out)
        :else
        (return
         (-/roots-tail-at
          i-roots (+ i-position 1) i-count
          (|| i-out
              (pg/jsonb-build-array (:text (:->> i-roots i-position))))))))

(defn.pg ^{:- [:boolean]}
  truthy
  "Hara truthiness: only nil and false are false."
  {:added "0.7"}
  [:bytea i-value-root]
  (let [o-cell (cell/cell-by-hash i-value-root)]
    (return
     (and [o-cell :is-not-null]
          (not (== (:smallint (:->> o-cell "type_tag")) 0))
          (not (and (== (:smallint (:->> o-cell "type_tag")) 1)
                    (== (:bytea (:->> o-cell "payload"))
                        (pg/decode "00" "hex"))))))))

(defn.pg ^{:- [:boolean]}
  integer-root
  {:added "0.7"}
  [:bytea i-root]
  (let [o-cell (cell/cell-by-hash i-root)]
    (return (and [o-cell :is-not-null]
                 (== (:smallint (:->> o-cell "type_tag")) 2)))))

(defn.pg ^{:- [:boolean]}
  string-root
  {:added "0.7"}
  [:bytea i-root]
  (let [o-cell (cell/cell-by-hash i-root)]
    (return (and [o-cell :is-not-null]
                 (== (:smallint (:->> o-cell "type_tag")) 5)))))

(defn.pg ^{:- [:jsonb]}
  vector-roots-at
  "Reconstructs a vector's roots from authoritative CellRef order."
  {:added "0.7"}
  [:bytea i-vector-root :integer i-position :integer i-count :jsonb i-out]
  (cond (>= i-position i-count)
        (return i-out)
        :else
        (let [(:bytea v-root)
              (cell/cell-ref-child i-vector-root i-position "element")
              (:jsonb v-next)
              (|| i-out
                  (pg/jsonb-build-array (pg/encode v-root "hex")))]
          (return (-/vector-roots-at
                   i-vector-root (+ i-position 1) i-count v-next)))))

(defn.pg ^{:- [:jsonb]}
  vector-roots
  {:added "0.7"}
  [:bytea i-vector-root]
  (let [o-vector (cell/cell-by-hash i-vector-root)
        _ (pg/assert (and [o-vector :is-not-null]
                          (== (:smallint (:->> o-vector "type_tag")) 10))
                     [:ledger/not-vector])
        (:integer v-count) (cell/cell-ref-count i-vector-root "element")]
    (return (-/vector-roots-at
             i-vector-root 0 v-count (pg/jsonb-build-array)))))

(defn.pg ^{:- [:jsonb]}
  evaluated-roots
  {:added "0.7"}
  [:bytea i-context-root :jsonb i-roots]
  (let [o-context (context/context-get i-context-root)]
    (return {:status "ok"
             :context-root i-context-root
             :roots i-roots
             :cost-used (:bigint (:->> o-context "cost_used"))})))

(defn.pg ^{:- [:jsonb]}
  evaluate-children-at
  "Evaluates an operation child range left-to-right."
  {:added "0.7"}
  [:bytea i-context-root :bytea i-op-root :integer i-position
   :integer i-count :jsonb i-roots]
  (cond (>= i-position i-count)
        (return (-/evaluated-roots i-context-root i-roots))
        :else
        (let [(:bytea v-child-root) (op/op-child-root i-op-root i-position)
              o-result (-/execute i-context-root v-child-root)]
          (cond (== (:text (:->> o-result "status")) "error")
                (return o-result)
                :else
                (let [(:jsonb v-next-roots)
                      (|| i-roots
                          (pg/jsonb-build-array
                           (pg/encode
                            (:bytea (:->> o-result "value_root")) "hex")))]
                  (return (-/evaluate-children-at
                           (:bytea (:->> o-result "context_root"))
                           i-op-root (+ i-position 1) i-count v-next-roots)))))))

(defn.pg ^{:- [:jsonb]}
  evaluate-children
  {:added "0.7"}
  [:bytea i-context-root :bytea i-op-root :integer i-start]
  (return (-/evaluate-children-at
           i-context-root i-op-root i-start
           (cell/cell-ref-count i-op-root "op-child")
           (pg/jsonb-build-array))))

(defn.pg ^{:- [:bytea]}
  map-from-roots-at
  {:added "0.7"}
  [:jsonb i-roots :integer i-position :integer i-count :bytea i-map-root]
  (cond (>= i-position i-count)
        (return i-map-root)
        :else
        (let [(:bytea v-next)
              (value/map-assoc i-map-root
                               (-/root-at i-roots i-position)
                               (-/root-at i-roots (+ i-position 1)))]
          (return (-/map-from-roots-at
                   i-roots (+ i-position 2) i-count v-next)))))

(defn.pg ^{:- [:text]}
  string-concat-at
  {:added "0.7"}
  [:jsonb i-roots :integer i-position :integer i-count :text i-out]
  (cond (>= i-position i-count)
        (return i-out)
        :else
        (let [(:bytea v-root) (-/root-at i-roots i-position)
              o-cell (cell/cell-by-hash v-root)
              _ (when (or [o-cell :is-null]
                          (not (== (:smallint (:->> o-cell "type_tag")) 5)))
                  (return nil))
              (:text v-next)
              (|| i-out (convert-from (:bytea (:->> o-cell "payload")) "UTF8"))]
          (return (-/string-concat-at
                   i-roots (+ i-position 1) i-count v-next)))))

(defn.pg ^{:- [:jsonb]}
  apply-integer-binary
  {:added "0.7"}
  [:bytea i-context-root :text i-primitive-id :jsonb i-roots]
  (let [(:bytea v-left-root) (-/root-at i-roots 0)
        (:bytea v-right-root) (-/root-at i-roots 1)
        _ (when (not (and (-/integer-root v-left-root)
                          (-/integer-root v-right-root)))
            (return (runtime/result-error i-context-root "integer-required")))
        (:bigint v-left) (value/integer-bigint v-left-root)
        (:bigint v-right) (value/integer-bigint v-right-root)
        (:bytea v-result-root)
        (pg/case (== i-primitive-id "integer/add")
                 (value/put-integer-number (+ v-left v-right))
                 (== i-primitive-id "integer/subtract")
                 (value/put-integer-number (- v-left v-right))
                 (== i-primitive-id "integer/multiply")
                 (value/put-integer-number (* v-left v-right))
                 (== i-primitive-id "integer/less-than")
                 (value/put-boolean (< v-left v-right))
                 (== i-primitive-id "integer/less-than-or-equal")
                 (value/put-boolean (<= v-left v-right))
                 (== i-primitive-id "integer/greater-than")
                 (value/put-boolean (> v-left v-right))
                 (== i-primitive-id "integer/greater-than-or-equal")
                 (value/put-boolean (>= v-left v-right))
                 :else
                 (value/put-boolean (== v-left v-right)))
        (:bytea v-next-context) (context/context-charge i-context-root 1)]
    (return (runtime/result-ok v-next-context v-result-root))))

(defn.pg ^{:- [:jsonb]}
  apply-primitive
  "Applies a primitive to already evaluated canonical roots."
  {:added "0.7"}
  [:bytea i-context-root :text i-primitive-id :jsonb i-roots]
  (let [(:integer v-count) (pg/jsonb-array-length i-roots)
        _ (when (not (context/context-can-charge i-context-root 1))
            (return (runtime/result-error i-context-root "cost-limit")))]
    (cond (or (== i-primitive-id "integer/add")
              (== i-primitive-id "integer/subtract")
              (== i-primitive-id "integer/multiply")
              (== i-primitive-id "integer/less-than")
              (== i-primitive-id "integer/less-than-or-equal")
              (== i-primitive-id "integer/greater-than")
              (== i-primitive-id "integer/greater-than-or-equal")
              (== i-primitive-id "integer/equal"))
          (return (-/apply-integer-binary
                   i-context-root i-primitive-id i-roots))

          (== i-primitive-id "value/equal")
          (return
           (runtime/result-ok
            (context/context-charge i-context-root 1)
            (value/put-boolean
             (== (-/root-at i-roots 0) (-/root-at i-roots 1)))))

          (== i-primitive-id "boolean/not")
          (return
           (runtime/result-ok
            (context/context-charge i-context-root 1)
            (value/put-boolean (not (-/truthy (-/root-at i-roots 0))))))

          (== i-primitive-id "vector/new")
          (return
           (runtime/result-ok
            (context/context-charge i-context-root 1)
            (value/put-vector i-roots)))

          (== i-primitive-id "vector/count")
          (let [(:bytea v-vector-root) (-/root-at i-roots 0)
                o-vector (cell/cell-by-hash v-vector-root)]
            (cond (or [o-vector :is-null]
                      (not (== (:smallint (:->> o-vector "type_tag")) 10)))
                  (return (runtime/result-error i-context-root "vector-required"))
                  :else
                  (return
                   (runtime/result-ok
                    (context/context-charge i-context-root 1)
                    (value/put-integer-number
                     (cell/cell-ref-count v-vector-root "element"))))))

          (== i-primitive-id "vector/get")
          (let [(:bytea v-vector-root) (-/root-at i-roots 0)
                (:bytea v-index-root) (-/root-at i-roots 1)
                o-vector (cell/cell-by-hash v-vector-root)
                _ (when (or [o-vector :is-null]
                            (not (== (:smallint (:->> o-vector "type_tag")) 10))
                            (not (-/integer-root v-index-root)))
                    (return (runtime/result-error i-context-root
                                                  "vector-and-index-required")))
                (:integer v-index) (:integer (value/integer-bigint v-index-root))
                (:bytea v-value-root) (value/vector-get v-vector-root v-index)]
            (return
             (runtime/result-ok
              (context/context-charge i-context-root 1)
              (pg/case [v-value-root :is-null]
                       (value/put-nil)
                       :else v-value-root))))

          (== i-primitive-id "map/new")
          (cond (not (== (pg/mod v-count 2) 0))
                (return (runtime/result-error i-context-root "map-even-arity"))
                :else
                (let [(:bytea v-map-root)
                      (-/map-from-roots-at
                       i-roots 0 v-count
                       (value/put-map (pg/jsonb-build-array)))]
                  (return
                   (runtime/result-ok
                    (context/context-charge i-context-root 1) v-map-root))))

          (== i-primitive-id "map/get")
          (let [(:bytea v-map-root) (-/root-at i-roots 0)
                o-map (cell/cell-by-hash v-map-root)
                _ (when (or [o-map :is-null]
                            (not (== (:smallint (:->> o-map "type_tag")) 11)))
                    (return (runtime/result-error i-context-root "map-required")))
                (:bytea v-value-root)
                (value/map-get v-map-root (-/root-at i-roots 1))]
            (return
             (runtime/result-ok
              (context/context-charge i-context-root 1)
              (pg/case [v-value-root :is-null]
                       (value/put-nil)
                       :else v-value-root))))

          (== i-primitive-id "map/assoc")
          (let [(:bytea v-map-root) (-/root-at i-roots 0)
                o-map (cell/cell-by-hash v-map-root)
                _ (when (or [o-map :is-null]
                            (not (== (:smallint (:->> o-map "type_tag")) 11)))
                    (return (runtime/result-error i-context-root "map-required")))
                (:bytea v-value-root)
                (value/map-assoc v-map-root
                                 (-/root-at i-roots 1)
                                 (-/root-at i-roots 2))]
            (return
             (runtime/result-ok
              (context/context-charge i-context-root 1) v-value-root)))

          (== i-primitive-id "string/concat")
          (let [(:text v-text) (-/string-concat-at i-roots 0 v-count "")]
            (cond [v-text :is-null]
                  (return (runtime/result-error i-context-root "string-required"))
                  :else
                  (return
                   (runtime/result-ok
                    (context/context-charge i-context-root 1)
                    (value/put-string v-text)))))

          :else
          (return (runtime/result-error i-context-root "unknown-primitive")))))

(defn.pg ^{:- [:jsonb]}
  invoke-function-roots
  "Calls a persistent function of any fixed arity and restores the caller frame."
  {:added "0.7"}
  [:bytea i-context-root :bytea i-function-root :jsonb i-argument-roots]
  (let [o-function (function/function-get i-function-root)
        o-caller (context/context-get i-context-root)
        _ (when (or [o-function :is-null]
                    (not (function/function-valid i-function-root)))
            (return (runtime/result-error i-context-root "invalid-function")))
        (:integer v-parameter-count)
        (cell/cell-ref-count
         (:bytea (:->> o-function "parameters_root")) "element")
        (:integer v-argument-count) (pg/jsonb-array-length i-argument-roots)
        _ (when (not (== v-parameter-count v-argument-count))
            (return (runtime/result-error i-context-root "arity")))
        _ (when (>= (:integer (:->> o-caller "depth")) 64)
            (return (runtime/result-error i-context-root "max-depth")))
        _ (when (not (context/context-can-charge i-context-root 2))
            (return (runtime/result-error i-context-root "cost-limit")))
        (:bytea v-closure-root) (:bytea (:->> o-function "closure_root"))
        (:jsonb v-closure-roots) (-/vector-roots v-closure-root)
        (:bytea v-frame-root)
        (value/put-vector (|| i-argument-roots v-closure-roots))
        (:bytea v-function-context)
        (context/context-with-locals
         i-context-root v-frame-root
         (+ (:integer (:->> o-caller "depth")) 1))
        (:bytea v-call-context) (context/context-charge v-function-context 2)
        o-body-result
        (-/execute v-call-context (:bytea (:->> o-function "body_root")))
        _ (when (== (:text (:->> o-body-result "status")) "error")
            (return o-body-result))
        (:bytea v-restored-context)
        (context/context-with-locals
         (:bytea (:->> o-body-result "context_root"))
         (:bytea (:->> o-caller "locals_root"))
         (:integer (:->> o-caller "depth")))]
    (return
     (runtime/result-ok
      v-restored-context (:bytea (:->> o-body-result "value_root"))))))

(defn.pg ^{:- [:jsonb]}
  invoke-protocol-roots
  {:added "0.7"}
  [:bytea i-context-root :bytea i-protocol-root
   :bytea i-method-name-root :jsonb i-argument-roots]
  (let [(:integer v-count) (pg/jsonb-array-length i-argument-roots)
        (:bigint v-declared-arity)
        (protocol/method-arity i-protocol-root i-method-name-root)
        _ (when (not (== v-declared-arity v-count))
            (return (runtime/result-error i-context-root "protocol/method-arity")))
        o-context (context/context-get i-context-root)
        (:bytea v-receiver-root) (-/root-at i-argument-roots 0)
        (:bytea v-function-root)
        (protocol/resolve-method
         (:bytea (:->> o-context "state_root"))
         (:bytea (:->> o-context "address"))
         i-protocol-root i-method-name-root v-receiver-root)]
    (cond [v-function-root :is-null]
          (return (runtime/result-error
                   i-context-root "missing-protocol-implementation"))
          :else
          (return (-/invoke-function-roots
                   i-context-root v-function-root i-argument-roots)))))

(defn.pg ^{:- [:jsonb]}
  invoke-callable-root
  "Calls a primitive, function, or protocol dispatcher value."
  {:added "0.7"}
  [:bytea i-context-root :bytea i-callable-root :jsonb i-argument-roots]
  (let [o-primitive (primitive/primitive-get-root i-callable-root)
        o-function (function/function-get i-callable-root)
        (:integer v-count) (pg/jsonb-array-length i-argument-roots)]
    (cond [o-primitive :is-not-null]
          (let [(:integer v-arity) (:integer (:->> o-primitive "arity"))
                (:text v-id) (:text (:->> o-primitive "primitive_id"))]
            (cond (and (not (== v-arity -1)) (not (== v-arity v-count)))
                  (return (runtime/result-error i-context-root "arity"))
                  (== v-id "protocol/define")
                  (return
                   (protocol/define-transition
                    i-context-root
                    (-/root-at i-argument-roots 0)
                    (-/root-at i-argument-roots 1)))
                  (== v-id "protocol/extend")
                  (return
                   (protocol/extend-transition
                    i-context-root
                    (-/root-at i-argument-roots 0)
                    (-/root-at i-argument-roots 1)
                    (-/root-at i-argument-roots 2)))
                  (== v-id "protocol/invoke")
                  (return
                   (-/invoke-protocol-roots
                    i-context-root
                    (-/root-at i-argument-roots 0)
                    (-/root-at i-argument-roots 1)
                    (-/roots-tail-at
                     i-argument-roots 2 v-count (pg/jsonb-build-array))))
                  :else
                  (return (-/apply-primitive
                           i-context-root v-id i-argument-roots))))

          [o-function :is-not-null]
          (return (-/invoke-function-roots
                   i-context-root i-callable-root i-argument-roots))

          (protocol/protocol-method-valid i-callable-root)
          (return
           (-/invoke-protocol-roots
            i-context-root
            (protocol/record-field i-callable-root "protocol/root")
            (protocol/record-field i-callable-root "method/name")
            i-argument-roots))

          :else
          (return (runtime/result-error i-context-root "unknown-callable")))))

(defn.pg ^{:- [:jsonb]}
  execute-invoke
  "Supports both static calls and dynamic calls whose first child yields a callable."
  {:added "0.7"}
  [:bytea i-context-root :bytea i-op-root]
  (let [o-op (op/op-get i-op-root)
        (:bytea v-static-root) (:bytea (:->> o-op "function_root"))
        (:integer v-count) (cell/cell-ref-count i-op-root "op-child")]
    (cond [v-static-root :is-not-null]
          (let [o-arguments (-/evaluate-children i-context-root i-op-root 0)
                _ (when (== (:text (:->> o-arguments "status")) "error")
                    (return o-arguments))]
            (return
             (-/invoke-callable-root
              (:bytea (:->> o-arguments "context_root"))
              v-static-root
              (:jsonb (:->> o-arguments "roots")))))

          (< v-count 1)
          (return (runtime/result-error i-context-root "call-requires-callee"))

          :else
          (let [o-callee
                (-/execute i-context-root (op/op-child-root i-op-root 0))
                _ (when (== (:text (:->> o-callee "status")) "error")
                    (return o-callee))
                o-arguments
                (-/evaluate-children-at
                 (:bytea (:->> o-callee "context_root"))
                 i-op-root 1 v-count (pg/jsonb-build-array))
                _ (when (== (:text (:->> o-arguments "status")) "error")
                    (return o-arguments))]
            (return
             (-/invoke-callable-root
              (:bytea (:->> o-arguments "context_root"))
              (:bytea (:->> o-callee "value_root"))
              (:jsonb (:->> o-arguments "roots"))))))))

(defn.pg ^{:- [:jsonb]}
  execute-let
  "Evaluates one lexical binding; nesting represents multi-binding let."
  {:added "0.7"}
  [:bytea i-context-root :bytea i-op-root]
  (let [(:integer v-count) (cell/cell-ref-count i-op-root "op-child")
        _ (when (not (== v-count 2))
            (return (runtime/result-error i-context-root "let-arity")))
        o-binding (-/execute i-context-root (op/op-child-root i-op-root 0))
        _ (when (== (:text (:->> o-binding "status")) "error")
            (return o-binding))
        (:bytea v-binding-context-root)
        (:bytea (:->> o-binding "context_root"))
        o-binding-context (context/context-get v-binding-context-root)
        (:jsonb v-outer-roots)
        (-/vector-roots (:bytea (:->> o-binding-context "locals_root")))
        (:bytea v-frame-root)
        (value/put-vector
         (|| v-outer-roots
             (pg/jsonb-build-array
              (pg/encode (:bytea (:->> o-binding "value_root")) "hex"))))
        _ (when (not (context/context-can-charge v-binding-context-root 1))
            (return (runtime/result-error v-binding-context-root "cost-limit")))
        (:bytea v-body-context)
        (context/context-charge
         (context/context-with-locals
          v-binding-context-root v-frame-root
          (+ (:integer (:->> o-binding-context "depth")) 1))
         1)
        o-body (-/execute v-body-context (op/op-child-root i-op-root 1))
        _ (when (== (:text (:->> o-body "status")) "error")
            (return o-body))
        (:bytea v-restored-context)
        (context/context-with-locals
         (:bytea (:->> o-body "context_root"))
         (:bytea (:->> o-binding-context "locals_root"))
         (:integer (:->> o-binding-context "depth")))]
    (return
     (runtime/result-ok
      v-restored-context (:bytea (:->> o-body "value_root"))))))

(defn.pg ^{:- [:jsonb]}
  execute-def
  "Defines the result of any deterministic expression."
  {:added "0.7"}
  [:bytea i-context-root :bytea i-op-root]
  (let [o-op (op/op-get i-op-root)
        (:integer v-count) (cell/cell-ref-count i-op-root "op-child")
        _ (when (not (== v-count 1))
            (return (runtime/result-error i-context-root "def-arity")))
        o-value (-/execute i-context-root (op/op-child-root i-op-root 0))
        _ (when (== (:text (:->> o-value "status")) "error")
            (return o-value))
        (:bytea v-value-context-root) (:bytea (:->> o-value "context_root"))
        o-value-context (context/context-get v-value-context-root)
        _ (when (not (context/context-can-charge v-value-context-root 2))
            (return (runtime/result-error v-value-context-root "cost-limit")))
        (:bytea v-account-root)
        (state/state-account-root
         (:bytea (:->> o-value-context "state_root"))
         (:bytea (:->> o-value-context "address")))
        _ (when [v-account-root :is-null]
            (return (runtime/result-error v-value-context-root "missing-account")))
        (:bytea v-next-account)
        (account/account-value-define
         v-account-root (:bytea (:->> o-op "symbol_root"))
         (:bytea (:->> o-value "value_root")))
        (:bytea v-next-state)
        (state/state-assoc-account
         (:bytea (:->> o-value-context "state_root"))
         (:bytea (:->> o-value-context "address"))
         v-next-account (:bigint (:->> o-value-context "block_height")))
        (:bytea v-next-context)
        (context/context-charge
         (context/context-with-state v-value-context-root v-next-state) 2)]
    (return
     (runtime/result-ok
      v-next-context (:bytea (:->> o-value "value_root"))))))

(defn.pg ^{:- [:jsonb]}
  execute-cond-at
  {:added "0.7"}
  [:bytea i-context-root :bytea i-op-root :integer i-position :integer i-count]
  (cond (>= i-position i-count)
        (return (runtime/result-ok i-context-root (value/put-nil)))
        :else
        (let [o-test (-/execute i-context-root
                               (op/op-child-root i-op-root i-position))
              _ (when (== (:text (:->> o-test "status")) "error")
                  (return o-test))]
          (cond (-/truthy (:bytea (:->> o-test "value_root")))
                (return
                 (-/execute
                  (:bytea (:->> o-test "context_root"))
                  (op/op-child-root i-op-root (+ i-position 1))))
                :else
                (return
                 (-/execute-cond-at
                  (:bytea (:->> o-test "context_root"))
                  i-op-root (+ i-position 2) i-count))))))

(defn.pg ^{:- [:jsonb]}
  execute-cond
  {:added "0.7"}
  [:bytea i-context-root :bytea i-op-root]
  (let [(:integer v-count) (cell/cell-ref-count i-op-root "op-child")]
    (cond (not (== (pg/mod v-count 2) 0))
          (return (runtime/result-error i-context-root
                                        "uneven-condition-children"))
          :else
          (return (-/execute-cond-at
                   i-context-root i-op-root 0 v-count)))))

(defn.pg ^{:- [:jsonb]}
  execute-do-at
  {:added "0.7"}
  [:bytea i-context-root :bytea i-op-root :integer i-position
   :integer i-count :jsonb i-last]
  (cond (>= i-position i-count)
        (return i-last)
        :else
        (let [o-result (-/execute i-context-root
                                 (op/op-child-root i-op-root i-position))]
          (cond (== (:text (:->> o-result "status")) "error")
                (return o-result)
                :else
                (return
                 (-/execute-do-at
                  (:bytea (:->> o-result "context_root"))
                  i-op-root (+ i-position 1) i-count o-result))))))

(defn.pg ^{:- [:jsonb]}
  execute-do
  {:added "0.7"}
  [:bytea i-context-root :bytea i-op-root]
  (let [(:integer v-count) (cell/cell-ref-count i-op-root "op-child")]
    (cond (== v-count 0)
          (return (runtime/result-ok i-context-root (value/put-nil)))
          :else
          (return (-/execute-do-at i-context-root i-op-root 0 v-count nil)))))

(defn.pg ^{:- [:jsonb]}
  execute
  "Recursive deterministic evaluator used by signed Ignatius transactions."
  {:added "0.7"}
  [:bytea i-context-root :bytea i-op-root]
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
          (return (-/execute-invoke i-context-root i-op-root))
          (== v-kind "let")
          (return (-/execute-let i-context-root i-op-root))
          (== v-kind "def")
          (return (-/execute-def i-context-root i-op-root))
          (== v-kind "cond")
          (return (-/execute-cond i-context-root i-op-root))
          (== v-kind "do")
          (return (-/execute-do i-context-root i-op-root))
          :else
          (return (runtime/result-error i-context-root "unsupported-op")))))