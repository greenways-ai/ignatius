(ns gwdb.ledger.protocol
  (:require [tahto.core :as l]
            [postgres.core :as pg]
            [gwdb.ledger.cell :as cell]
            [gwdb.ledger.value :as value]
            [gwdb.ledger.account :as account]
            [gwdb.ledger.state :as state]
            [gwdb.ledger.context :as context]
            [gwdb.ledger.function :as function]))

(l/script :postgres
  {:require [[postgres.core :as pg]
             [gwdb.ledger.cell :as cell]
             [gwdb.ledger.value :as value]
             [gwdb.ledger.account :as account]
             [gwdb.ledger.state :as state]
             [gwdb.ledger.context :as context]
             [gwdb.ledger.function :as function]]
   :config {:dbname "gw-ledger-test"}
   :static {:application ["gw"]
            :all {:schema ["gw_ledger"]}}})

(defn.pg ^{:- [:jsonb]}
  result-ok
  {:added "0.5"}
  [:bytea i-context-root :bytea i-value-root]
  (let [o-context (context/context-get i-context-root)]
    (return {:status "ok"
             :context-root i-context-root
             :value-root i-value-root
             :cost-used (:bigint (:->> o-context "cost_used"))})))

(defn.pg ^{:- [:jsonb]}
  result-error
  {:added "0.5"}
  [:bytea i-context-root :text i-error-code]
  (let [o-context (context/context-get i-context-root)
        (:bigint v-cost-used)
        (pg/case [o-context :is-null] (:bigint 0)
                 :else (:bigint (:->> o-context "cost_used")))]
    (return {:status "error"
             :context-root i-context-root
             :error {:code i-error-code}
             :cost-used v-cost-used})))

(defn.pg ^{:- [:bytea]}
  keyword-root
  {:added "0.5"}
  [:text i-name]
  (return (value/put-keyword i-name)))

(defn.pg ^{:- [:bytea]}
  record-field
  {:added "0.5"}
  [:bytea i-record-root :text i-field]
  (return (value/map-get i-record-root (-/keyword-root i-field))))

(defn.pg ^{:- [:bytea]}
  record-start
  {:added "0.5"}
  [:text i-kind]
  (return
   (value/map-assoc
    (value/put-map (pg/jsonb-build-array))
    (-/keyword-root "record/type")
    (-/keyword-root i-kind))))

(defn.pg ^{:- [:bytea]}
  record-assoc
  {:added "0.5"}
  [:bytea i-record-root :text i-field :bytea i-value-root]
  (return
   (value/map-assoc i-record-root (-/keyword-root i-field) i-value-root)))

(defn.pg ^{:- [:boolean]}
  record-kind
  {:added "0.5"}
  [:bytea i-record-root :text i-kind]
  (let [o-cell (cell/cell-by-hash i-record-root)
        _ (when (or [o-cell :is-null]
                    (not (== (:smallint (:->> o-cell "type_tag")) 11)))
            (return false))
        (:bytea v-kind-root) (-/record-field i-record-root "record/type")]
    (return (== v-kind-root (-/keyword-root i-kind)))))

(defn.pg ^{:- [:boolean]}
  protocol-methods-valid-at
  {:added "0.5"}
  [:bytea i-methods-root :integer i-position :integer i-count]
  (cond (>= i-position i-count)
        (return true)
        :else
        (let [(:bytea v-name-root)
              (cell/cell-ref-child i-methods-root i-position "key")
              (:bytea v-arity-root)
              (cell/cell-ref-child i-methods-root i-position "value")
              o-name (cell/cell-by-hash v-name-root)
              o-arity (cell/cell-by-hash v-arity-root)
              (:text v-name)
              (pg/case [o-name :is-null] ""
                       :else (pg/encode (:bytea (:->> o-name "payload")) "escape"))]
          (cond (or [o-name :is-null]
                    [o-arity :is-null]
                    (not (== (:smallint (:->> o-name "type_tag")) 7))
                    (not (== (:smallint (:->> o-arity "type_tag")) 2))
                    [(pg/regexp-match v-name "!$") :is-not-null]
                    (< (value/integer-bigint v-arity-root) 1))
                (return false)
                :else
                (return (-/protocol-methods-valid-at
                         i-methods-root (+ i-position 1) i-count))))))

(defn.pg ^{:- [:boolean]}
  protocol-methods-valid
  {:added "0.5"}
  [:bytea i-methods-root]
  (let [o-methods (cell/cell-by-hash i-methods-root)]
    (return
     (and [o-methods :is-not-null]
          (== (:smallint (:->> o-methods "type_tag")) 11)
          (-/protocol-methods-valid-at
           i-methods-root 0 (cell/cell-ref-count i-methods-root "key"))))))

(defn.pg ^{:- [:bytea]}
  protocol-put
  "Commits a language protocol as an ordinary canonical HCV1 map."
  {:added "0.5"}
  [:bytea i-name-root :bytea i-methods-root]
  (let [_ (pg/assert (== (cell/cell-type-tag i-name-root) 7)
                     [:ledger/protocol-name-not-symbol])
        _ (pg/assert (-/protocol-methods-valid i-methods-root)
                     [:ledger/invalid-protocol-methods])
        (:bytea v-record) (-/record-start "protocol")
        (:bytea v-named) (-/record-assoc v-record "protocol/name" i-name-root)
        (:bytea v-complete)
        (-/record-assoc v-named "protocol/methods" i-methods-root)]
    (return v-complete)))

(defn.pg ^{:- [:boolean]}
  protocol-valid
  {:added "0.5"}
  [:bytea i-protocol-root]
  (let [_ (when (not (-/record-kind i-protocol-root "protocol"))
            (return false))
        (:bytea v-name-root) (-/record-field i-protocol-root "protocol/name")
        (:bytea v-methods-root) (-/record-field i-protocol-root "protocol/methods")
        o-name (cell/cell-by-hash v-name-root)]
    (return (and [o-name :is-not-null]
                 (== (:smallint (:->> o-name "type_tag")) 7)
                 (-/protocol-methods-valid v-methods-root)))))

(defn.pg ^{:- [:bytea]}
  protocol-method-put
  {:added "0.5"}
  [:bytea i-protocol-root :bytea i-name-root :bytea i-arity-root]
  (let [_ (pg/assert (-/protocol-valid i-protocol-root)
                     [:ledger/invalid-protocol])
        (:bytea v-record) (-/record-start "protocol-method")
        (:bytea v-protocol)
        (-/record-assoc v-record "protocol/root" i-protocol-root)
        (:bytea v-name) (-/record-assoc v-protocol "method/name" i-name-root)
        (:bytea v-complete) (-/record-assoc v-name "method/arity" i-arity-root)]
    (return v-complete)))

(defn.pg ^{:- [:boolean]}
  protocol-method-valid
  {:added "0.5"}
  [:bytea i-method-root]
  (let [_ (when (not (-/record-kind i-method-root "protocol-method"))
            (return false))
        (:bytea v-protocol-root) (-/record-field i-method-root "protocol/root")
        (:bytea v-name-root) (-/record-field i-method-root "method/name")
        (:bytea v-arity-root) (-/record-field i-method-root "method/arity")]
    (return (and (-/protocol-valid v-protocol-root)
                 (== (cell/cell-type-tag v-name-root) 7)
                 (== (cell/cell-type-tag v-arity-root) 2)
                 (>= (value/integer-bigint v-arity-root) 1)))))

(defn.pg ^{:- [:boolean]}
  protocol-bindings-available-at
  {:added "0.5"}
  [:bytea i-account-root :bytea i-protocol-root :bytea i-methods-root
   :integer i-position :integer i-count]
  (cond (>= i-position i-count)
        (return true)
        :else
        (let [(:bytea v-name-root)
              (cell/cell-ref-child i-methods-root i-position "key")
              (:bytea v-arity-root)
              (cell/cell-ref-child i-methods-root i-position "value")
              (:bytea v-method-root)
              (-/protocol-method-put i-protocol-root v-name-root v-arity-root)
              (:bytea v-existing)
              (account/account-value-lookup i-account-root v-name-root)]
          (cond (or [v-existing :is-null] (== v-existing v-method-root))
                (return (-/protocol-bindings-available-at
                         i-account-root i-protocol-root i-methods-root
                         (+ i-position 1) i-count))
                :else
                (return false)))))

(defn.pg ^{:- [:bytea]}
  protocol-bind-methods-at
  {:added "0.5"}
  [:bytea i-account-root :bytea i-protocol-root :bytea i-methods-root
   :integer i-position :integer i-count]
  (cond (>= i-position i-count)
        (return i-account-root)
        :else
        (let [(:bytea v-name-root)
              (cell/cell-ref-child i-methods-root i-position "key")
              (:bytea v-arity-root)
              (cell/cell-ref-child i-methods-root i-position "value")
              (:bytea v-method-root)
              (-/protocol-method-put i-protocol-root v-name-root v-arity-root)
              (:bytea v-next-account)
              (account/account-value-define i-account-root v-name-root v-method-root)]
          (return (-/protocol-bind-methods-at
                   v-next-account i-protocol-root i-methods-root
                   (+ i-position 1) i-count)))))

(defn.pg ^{:- [:jsonb]}
  define-transition
  "Defines a protocol value and its dispatchers in one immutable state transition."
  {:added "0.5"}
  [:bytea i-context-root :bytea i-name-root :bytea i-methods-root]
  (let [o-context (context/context-get i-context-root)
        _ (when [o-context :is-null]
            (return (-/result-error i-context-root "missing-context")))
        _ (when (not (-/protocol-methods-valid i-methods-root))
            (return (-/result-error i-context-root "invalid-protocol-methods")))
        (:integer v-count) (cell/cell-ref-count i-methods-root "key")
        (:integer v-cost) (+ 4 (* 2 v-count))
        _ (when (not (context/context-can-charge i-context-root v-cost))
            (return (-/result-error i-context-root "cost-limit")))
        (:bytea v-account-root)
        (state/state-account-root (:bytea (:->> o-context "state_root"))
                                  (:bytea (:->> o-context "address")))
        _ (when [v-account-root :is-null]
            (return (-/result-error i-context-root "missing-account")))
        (:bytea v-protocol-root) (-/protocol-put i-name-root i-methods-root)
        (:bytea v-existing)
        (account/account-value-lookup v-account-root i-name-root)
        _ (when (not (or [v-existing :is-null] (== v-existing v-protocol-root)))
            (return (-/result-error i-context-root "protocol-binding-conflict")))
        _ (when (not (-/protocol-bindings-available-at
                      v-account-root v-protocol-root i-methods-root 0 v-count))
            (return (-/result-error i-context-root "protocol-method-binding-conflict")))
        (:bytea v-with-protocol)
        (account/account-value-define v-account-root i-name-root v-protocol-root)
        (:bytea v-next-account)
        (-/protocol-bind-methods-at
         v-with-protocol v-protocol-root i-methods-root 0 v-count)
        (:bytea v-next-state)
        (state/state-assoc-account
         (:bytea (:->> o-context "state_root"))
         (:bytea (:->> o-context "address"))
         v-next-account
         (:bigint (:->> o-context "block_height")))
        (:bytea v-next-context)
        (context/context-charge
         (context/context-with-state i-context-root v-next-state) v-cost)]
    (return (-/result-ok v-next-context v-protocol-root))))

(defn.pg ^{:- [:bytea]}
  type-put
  "Commits a stable language type descriptor as a canonical map."
  {:added "0.5"}
  [:bytea i-name-root :integer i-representation-tag]
  (let [_ (pg/assert (== (cell/cell-type-tag i-name-root) 7)
                     [:ledger/type-name-not-symbol])
        _ (pg/assert (and (>= i-representation-tag 0)
                          (<= i-representation-tag 20))
                     [:ledger/invalid-representation-tag])
        (:bytea v-record) (-/record-start "type")
        (:bytea v-named) (-/record-assoc v-record "type/name" i-name-root)
        (:bytea v-complete)
        (-/record-assoc v-named "type/representation-tag"
                        (value/put-integer-number i-representation-tag))]
    (return v-complete)))

(defn.pg ^{:- [:boolean]}
  type-valid
  {:added "0.5"}
  [:bytea i-type-root]
  (let [_ (when (not (-/record-kind i-type-root "type")) (return false))
        (:bytea v-name-root) (-/record-field i-type-root "type/name")
        (:bytea v-tag-root) (-/record-field i-type-root "type/representation-tag")]
    (return (and (== (cell/cell-type-tag v-name-root) 7)
                 (== (cell/cell-type-tag v-tag-root) 2)
                 (>= (value/integer-bigint v-tag-root) 0)
                 (<= (value/integer-bigint v-tag-root) 20)))))

(defn.pg ^{:- [:bytea]}
  builtin-type-put
  {:added "0.5"}
  [:integer i-type-tag]
  (return (-/type-put
           (value/put-symbol (|| "hara.type/" (:text i-type-tag)))
           i-type-tag)))

(defn.pg ^{:- [:bytea]}
  typed-value-put
  "Wraps a semantic value with an explicit language type for dispatch."
  {:added "0.5"}
  [:bytea i-type-root :bytea i-value-root]
  (let [_ (pg/assert (-/type-valid i-type-root)
                     [:ledger/missing-type-descriptor])
        _ (pg/assert [(cell/cell-by-hash i-value-root) :is-not-null]
                     [:ledger/missing-typed-value])
        (:bytea v-record) (-/record-start "typed-value")
        (:bytea v-typed) (-/record-assoc v-record "typed/type" i-type-root)
        (:bytea v-complete) (-/record-assoc v-typed "typed/value" i-value-root)]
    (return v-complete)))

(defn.pg ^{:- [:boolean]}
  typed-value-valid
  {:added "0.5"}
  [:bytea i-typed-root]
  (let [_ (when (not (-/record-kind i-typed-root "typed-value"))
            (return false))
        (:bytea v-type-root) (-/record-field i-typed-root "typed/type")
        (:bytea v-value-root) (-/record-field i-typed-root "typed/value")]
    (return (and (-/type-valid v-type-root)
                 [(cell/cell-by-hash v-value-root) :is-not-null]))))

(defn.pg ^{:- [:bytea]}
  value-type-root
  {:added "0.5"}
  [:bytea i-value-root]
  (let [o-cell (cell/cell-by-hash i-value-root)]
    (cond [o-cell :is-null]
          (return nil)
          (-/typed-value-valid i-value-root)
          (return (-/record-field i-value-root "typed/type"))
          :else
          (return (-/builtin-type-put (:smallint (:->> o-cell "type_tag")))))))

(defn.pg ^{:- [:boolean]}
  implementation-methods-valid-at
  {:added "0.5"}
  [:bytea i-protocol-methods-root :bytea i-methods-root
   :integer i-position :integer i-count]
  (cond (>= i-position i-count)
        (return true)
        :else
        (let [(:bytea v-name-root)
              (cell/cell-ref-child i-protocol-methods-root i-position "key")
              (:bytea v-arity-root)
              (cell/cell-ref-child i-protocol-methods-root i-position "value")
              (:bytea v-function-root) (value/map-get i-methods-root v-name-root)
              o-function (function/function-get v-function-root)
              (:integer v-parameter-count)
              (pg/case [o-function :is-null] -1
                       :else (cell/cell-ref-count
                              (:bytea (:->> o-function "parameters_root")) "element"))]
          (cond (or [v-function-root :is-null]
                    [o-function :is-null]
                    (not (function/function-valid v-function-root))
                    (not (== v-parameter-count
                             (value/integer-bigint v-arity-root))))
                (return false)
                :else
                (return (-/implementation-methods-valid-at
                         i-protocol-methods-root i-methods-root
                         (+ i-position 1) i-count))))))

(defn.pg ^{:- [:boolean]}
  implementation-methods-valid
  {:added "0.5"}
  [:bytea i-protocol-root :bytea i-methods-root]
  (let [_ (when (not (-/protocol-valid i-protocol-root)) (return false))
        (:bytea v-protocol-methods-root)
        (-/record-field i-protocol-root "protocol/methods")
        o-methods (cell/cell-by-hash i-methods-root)
        _ (when (or [o-methods :is-null]
                    (not (== (:smallint (:->> o-methods "type_tag")) 11)))
            (return false))
        (:integer v-count) (cell/cell-ref-count v-protocol-methods-root "key")]
    (return
     (and (== v-count (cell/cell-ref-count i-methods-root "key"))
          (-/implementation-methods-valid-at
           v-protocol-methods-root i-methods-root 0 v-count)))))

(defn.pg ^{:- [:bytea]}
  implementation-put
  {:added "0.5"}
  [:bytea i-protocol-root :bytea i-type-root :bytea i-methods-root]
  (let [_ (pg/assert (-/protocol-valid i-protocol-root)
                     [:ledger/invalid-protocol])
        _ (pg/assert (-/type-valid i-type-root)
                     [:ledger/missing-type-descriptor])
        _ (pg/assert (-/implementation-methods-valid
                      i-protocol-root i-methods-root)
                     [:ledger/invalid-protocol-implementation])
        (:bytea v-record) (-/record-start "protocol-implementation")
        (:bytea v-protocol)
        (-/record-assoc v-record "implementation/protocol" i-protocol-root)
        (:bytea v-type)
        (-/record-assoc v-protocol "implementation/type" i-type-root)
        (:bytea v-complete)
        (-/record-assoc v-type "implementation/methods" i-methods-root)]
    (return v-complete)))

(defn.pg ^{:- [:boolean]}
  implementation-valid
  {:added "0.5"}
  [:bytea i-implementation-root]
  (let [_ (when (not (-/record-kind i-implementation-root
                                    "protocol-implementation"))
            (return false))
        (:bytea v-protocol-root)
        (-/record-field i-implementation-root "implementation/protocol")
        (:bytea v-type-root)
        (-/record-field i-implementation-root "implementation/type")
        (:bytea v-methods-root)
        (-/record-field i-implementation-root "implementation/methods")]
    (return (and (-/type-valid v-type-root)
                 (-/implementation-methods-valid
                  v-protocol-root v-methods-root)))))

(defn.pg ^{:- [:bytea]}
  implementation-key-root
  {:added "0.5"}
  [:bytea i-protocol-root :bytea i-type-root]
  (return
   (value/put-symbol
    (|| "ignatius.protocol.impl/"
        (pg/encode i-protocol-root "hex") "/"
        (pg/encode i-type-root "hex")))))

(defn.pg ^{:- [:jsonb]}
  extend-transition
  "Adds a complete protocol implementation through an immutable account binding."
  {:added "0.5"}
  [:bytea i-context-root :bytea i-protocol-name-root
   :bytea i-type-root :bytea i-methods-root]
  (let [o-context (context/context-get i-context-root)
        _ (when [o-context :is-null]
            (return (-/result-error i-context-root "missing-context")))
        (:bytea v-account-root)
        (state/state-account-root (:bytea (:->> o-context "state_root"))
                                  (:bytea (:->> o-context "address")))
        _ (when [v-account-root :is-null]
            (return (-/result-error i-context-root "missing-account")))
        (:bytea v-protocol-root)
        (account/account-value-lookup v-account-root i-protocol-name-root)
        _ (when (or [v-protocol-root :is-null]
                    (not (-/protocol-valid v-protocol-root)))
            (return (-/result-error i-context-root "missing-protocol")))
        _ (when (not (-/implementation-methods-valid
                      v-protocol-root i-methods-root))
            (return (-/result-error i-context-root
                                    "invalid-protocol-implementation")))
        (:integer v-count) (cell/cell-ref-count i-methods-root "key")
        (:integer v-cost) (+ 4 (* 2 v-count))
        _ (when (not (context/context-can-charge i-context-root v-cost))
            (return (-/result-error i-context-root "cost-limit")))
        (:bytea v-implementation-root)
        (-/implementation-put v-protocol-root i-type-root i-methods-root)
        (:bytea v-key-root)
        (-/implementation-key-root v-protocol-root i-type-root)
        (:bytea v-existing)
        (account/account-value-lookup v-account-root v-key-root)
        _ (when (not (or [v-existing :is-null]
                         (== v-existing v-implementation-root)))
            (return (-/result-error i-context-root
                                    "protocol-implementation-conflict")))
        (:bytea v-next-account)
        (account/account-value-define
         v-account-root v-key-root v-implementation-root)
        (:bytea v-next-state)
        (state/state-assoc-account
         (:bytea (:->> o-context "state_root"))
         (:bytea (:->> o-context "address"))
         v-next-account
         (:bigint (:->> o-context "block_height")))
        (:bytea v-next-context)
        (context/context-charge
         (context/context-with-state i-context-root v-next-state) v-cost)]
    (return (-/result-ok v-next-context v-implementation-root))))

(defn.pg ^{:- [:bytea]}
  resolve-method
  "Resolves a method implementation from the supplied immutable state."
  {:added "0.5"}
  [:bytea i-state-root :bytea i-address-root :bytea i-protocol-root
   :bytea i-method-name-root :bytea i-receiver-root]
  (let [(:bytea v-account-root)
        (state/state-account-root i-state-root i-address-root)
        (:bytea v-type-root) (-/value-type-root i-receiver-root)
        (:bytea v-key-root)
        (pg/case [v-type-root :is-null] nil
                 :else (-/implementation-key-root i-protocol-root v-type-root))
        (:bytea v-implementation-root)
        (pg/case (or [v-account-root :is-null] [v-key-root :is-null]) nil
                 :else (account/account-value-lookup v-account-root v-key-root))
        (:bytea v-methods-root)
        (pg/case (-/implementation-valid v-implementation-root)
                 (-/record-field v-implementation-root "implementation/methods")
                 :else nil)]
    (return
     (pg/case [v-methods-root :is-null] nil
              :else (value/map-get v-methods-root i-method-name-root)))))

(defn.pg ^{:- [:bigint]}
  method-arity
  {:added "0.5"}
  [:bytea i-protocol-root :bytea i-method-name-root]
  (let [(:bytea v-methods-root)
        (pg/case (-/protocol-valid i-protocol-root)
                 (-/record-field i-protocol-root "protocol/methods")
                 :else nil)
        (:bytea v-arity-root)
        (pg/case [v-methods-root :is-null] nil
                 :else (value/map-get v-methods-root i-method-name-root))]
    (return (pg/case [v-arity-root :is-null] -1
                     :else (value/integer-bigint v-arity-root)))))
