(ns gwdb.ledger.protocol
  (:require [tahto.core :as l]
            [postgres.core :as pg]
            [gwdb.ledger.cell :as cell]
            [gwdb.ledger.codec :as codec]
            [gwdb.ledger.value :as value]
            [gwdb.ledger.account :as account]
            [gwdb.ledger.state :as state]
            [gwdb.ledger.context :as context]
            [gwdb.ledger.function :as function]))

(l/script :postgres
  {:require [[postgres.core :as pg]
             [gwdb.ledger.cell :as cell]
             [gwdb.ledger.codec :as codec]
             [gwdb.ledger.value :as value]
             [gwdb.ledger.account :as account]
             [gwdb.ledger.state :as state]
             [gwdb.ledger.context :as context]
             [gwdb.ledger.function :as function]]
   :config {:dbname "gw-ledger-test"}
   :import [["pgcrypto"]]
   :static {:application ["gw"]
            :all {:schema ["gw_ledger"]}}})

(deftype.pg Protocol
  "Rebuildable descriptor for a canonical Hara language protocol."
  {:added "0.5"}
  [:protocol-root {:type :bytea :primary true}
   :name-root     {:type :bytea :required true}
   :methods-root  {:type :bytea :required true}])

(deftype.pg ProtocolMethod
  "Rebuildable descriptor for one protocol method dispatcher."
  {:added "0.5"}
  [:protocol-method-root {:type :bytea :primary true}
   :protocol-root        {:type :bytea :required true}
   :name-root            {:type :bytea :required true}
   :arity-root           {:type :bytea :required true}])

(deftype.pg ProtocolImplementation
  "Rebuildable descriptor for one protocol/type implementation map."
  {:added "0.5"}
  [:implementation-root {:type :bytea :primary true}
   :protocol-root       {:type :bytea :required true}
   :type-root           {:type :bytea :required true}
   :methods-root        {:type :bytea :required true}])

(deftype.pg TypeDescriptor
  "Canonical language type identity used by protocol dispatch."
  {:added "0.5"}
  [:type-root               {:type :bytea :primary true}
   :name-root               {:type :bytea :required true}
   :representation-tag-root {:type :bytea :required true}])

(deftype.pg TypedValue
  "Canonical wrapper binding a semantic value to a language type root."
  {:added "0.5"}
  [:typed-root {:type :bytea :primary true}
   :type-root  {:type :bytea :required true}
   :value-root {:type :bytea :required true}])

(defn.pg ^{:- [:text]}
  root-hex
  {:added "0.5"}
  [:bytea i-root]
  (return (pg/encode i-root "hex")))

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
  protocol-payload
  {:added "0.5"}
  [:bytea i-name-root :bytea i-methods-root]
  (return
   (pg/decode
    (|| "R:protocol:1:2:"
        (-/root-hex i-name-root)
        (-/root-hex i-methods-root))
    "escape")))

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
  "Commits a language protocol name and canonical method->arity map."
  {:added "0.5"}
  [:bytea i-name-root :bytea i-methods-root]
  (let [o-name (cell/cell-by-hash i-name-root)
        _ (pg/assert (and [o-name :is-not-null]
                          (== (:smallint (:->> o-name "type_tag")) 7))
                     [:ledger/protocol-name-not-symbol])
        _ (pg/assert (-/protocol-methods-valid i-methods-root)
                     [:ledger/invalid-protocol-methods])
        (:bytea v-payload) (-/protocol-payload i-name-root i-methods-root)
        (:bytea v-root) (cell/cell-put (codec/canonical-hash 14 v-payload)
                                       1 14 v-payload)
        o-name-ref (cell/cell-ref-put v-root 0 "protocol/name" i-name-root)
        o-methods-ref (cell/cell-ref-put v-root 1 "protocol/methods" i-methods-root)
        o-row (pg/t:upsert -/Protocol
                            {:protocol-root v-root
                             :name-root i-name-root
                             :methods-root i-methods-root})]
    (return v-root)))

(defn.pg protocol-get
  {:added "0.5"}
  [:bytea i-protocol-root]
  (return (pg/t:get -/Protocol {:where {:protocol-root i-protocol-root}})))

(defn.pg ^{:- [:boolean]}
  protocol-valid
  {:added "0.5"}
  [:bytea i-protocol-root]
  (let [o-cell (cell/cell-by-hash i-protocol-root)
        o-protocol (-/protocol-get i-protocol-root)
        _ (when (or [o-cell :is-null] [o-protocol :is-null]) (return false))
        (:bytea v-payload)
        (-/protocol-payload (:bytea (:->> o-protocol "name_root"))
                            (:bytea (:->> o-protocol "methods_root")))]
    (return (and (== (:smallint (:->> o-cell "type_tag")) 14)
                 (== (:bytea (:->> o-cell "payload")) v-payload)
                 (codec/verify i-protocol-root 14 v-payload)
                 (-/protocol-methods-valid
                  (:bytea (:->> o-protocol "methods_root"))))))

(defn.pg ^{:- [:bytea]}
  protocol-method-payload
  {:added "0.5"}
  [:bytea i-protocol-root :bytea i-name-root :bytea i-arity-root]
  (return
   (pg/decode
    (|| "R:protocol-method:1:3:"
        (-/root-hex i-protocol-root)
        (-/root-hex i-name-root)
        (-/root-hex i-arity-root))
    "escape")))

(defn.pg ^{:- [:bytea]}
  protocol-method-put
  {:added "0.5"}
  [:bytea i-protocol-root :bytea i-name-root :bytea i-arity-root]
  (let [_ (pg/assert (-/protocol-valid i-protocol-root)
                     [:ledger/invalid-protocol])
        _ (pg/assert (== (cell/cell-type-tag i-name-root) 7)
                     [:ledger/protocol-method-name-not-symbol])
        _ (pg/assert (and (== (cell/cell-type-tag i-arity-root) 2)
                          (>= (value/integer-bigint i-arity-root) 1))
                     [:ledger/invalid-protocol-method-arity])
        (:bytea v-payload)
        (-/protocol-method-payload i-protocol-root i-name-root i-arity-root)
        (:bytea v-root) (cell/cell-put (codec/canonical-hash 14 v-payload)
                                       1 14 v-payload)
        o-protocol-ref (cell/cell-ref-put v-root 0 "protocol" i-protocol-root)
        o-name-ref (cell/cell-ref-put v-root 1 "method/name" i-name-root)
        o-arity-ref (cell/cell-ref-put v-root 2 "method/arity" i-arity-root)
        o-row (pg/t:upsert -/ProtocolMethod
                            {:protocol-method-root v-root
                             :protocol-root i-protocol-root
                             :name-root i-name-root
                             :arity-root i-arity-root})]
    (return v-root)))

(defn.pg protocol-method-get
  {:added "0.5"}
  [:bytea i-method-root]
  (return (pg/t:get -/ProtocolMethod
                    {:where {:protocol-method-root i-method-root}})))

(defn.pg ^{:- [:boolean]}
  protocol-method-valid
  {:added "0.5"}
  [:bytea i-method-root]
  (let [o-cell (cell/cell-by-hash i-method-root)
        o-method (-/protocol-method-get i-method-root)
        _ (when (or [o-cell :is-null] [o-method :is-null]) (return false))
        (:bytea v-payload)
        (-/protocol-method-payload
         (:bytea (:->> o-method "protocol_root"))
         (:bytea (:->> o-method "name_root"))
         (:bytea (:->> o-method "arity_root")))]
    (return (and (== (:smallint (:->> o-cell "type_tag")) 14)
                 (== (:bytea (:->> o-cell "payload")) v-payload)
                 (codec/verify i-method-root 14 v-payload)))))

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
  "Defines a protocol value and its method dispatchers in one immutable account transition."
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
        (:bytea v-existing-protocol)
        (account/account-value-lookup v-account-root i-name-root)
        _ (when (not (or [v-existing-protocol :is-null]
                         (== v-existing-protocol v-protocol-root)))
            (return (-/result-error i-context-root "protocol-binding-conflict")))
        _ (when (not (-/protocol-bindings-available-at
                      v-account-root v-protocol-root i-methods-root 0 v-count))
            (return (-/result-error i-context-root "protocol-method-binding-conflict")))
        (:bytea v-protocol-account)
        (account/account-value-define v-account-root i-name-root v-protocol-root)
        (:bytea v-next-account)
        (-/protocol-bind-methods-at
         v-protocol-account v-protocol-root i-methods-root 0 v-count)
        (:bytea v-next-state)
        (state/state-assoc-account
         (:bytea (:->> o-context "state_root"))
         (:bytea (:->> o-context "address"))
         v-next-account
         (:bigint (:->> o-context "block_height")))
        (:bytea v-state-context)
        (context/context-with-state i-context-root v-next-state)
        (:bytea v-next-context) (context/context-charge v-state-context v-cost)]
    (return (-/result-ok v-next-context v-protocol-root))))

(defn.pg ^{:- [:bytea]}
  type-payload
  {:added "0.5"}
  [:bytea i-name-root :bytea i-representation-tag-root]
  (return
   (pg/decode
    (|| "R:type:1:2:"
        (-/root-hex i-name-root)
        (-/root-hex i-representation-tag-root))
    "escape")))

(defn.pg ^{:- [:bytea]}
  type-put
  "Commits a stable language type identity."
  {:added "0.5"}
  [:bytea i-name-root :integer i-representation-tag]
  (let [_ (pg/assert (== (cell/cell-type-tag i-name-root) 7)
                     [:ledger/type-name-not-symbol])
        _ (pg/assert (and (>= i-representation-tag 0)
                          (<= i-representation-tag 20))
                     [:ledger/invalid-representation-tag])
        (:bytea v-tag-root) (value/put-integer-number i-representation-tag)
        (:bytea v-payload) (-/type-payload i-name-root v-tag-root)
        (:bytea v-root) (cell/cell-put (codec/canonical-hash 14 v-payload)
                                       1 14 v-payload)
        o-name-ref (cell/cell-ref-put v-root 0 "type/name" i-name-root)
        o-tag-ref (cell/cell-ref-put v-root 1 "type/representation-tag" v-tag-root)
        o-row (pg/t:upsert -/TypeDescriptor
                            {:type-root v-root
                             :name-root i-name-root
                             :representation-tag-root v-tag-root})]
    (return v-root)))

(defn.pg type-get
  {:added "0.5"}
  [:bytea i-type-root]
  (return (pg/t:get -/TypeDescriptor {:where {:type-root i-type-root}})))

(defn.pg ^{:- [:bytea]}
  builtin-type-put
  {:added "0.5"}
  [:integer i-type-tag]
  (return (-/type-put
           (value/put-symbol (|| "hara.type/" (:text i-type-tag)))
           i-type-tag)))

(defn.pg ^{:- [:bytea]}
  typed-value-payload
  {:added "0.5"}
  [:bytea i-type-root :bytea i-value-root]
  (return
   (pg/decode
    (|| "R:typed-value:1:2:"
        (-/root-hex i-type-root)
        (-/root-hex i-value-root))
    "escape")))

(defn.pg ^{:- [:bytea]}
  typed-value-put
  "Wraps a semantic value with an explicit language type for dispatch."
  {:added "0.5"}
  [:bytea i-type-root :bytea i-value-root]
  (let [_ (pg/assert [(-/type-get i-type-root) :is-not-null]
                     [:ledger/missing-type-descriptor])
        _ (pg/assert [(cell/cell-by-hash i-value-root) :is-not-null]
                     [:ledger/missing-typed-value])
        (:bytea v-payload) (-/typed-value-payload i-type-root i-value-root)
        (:bytea v-root) (cell/cell-put (codec/canonical-hash 14 v-payload)
                                       1 14 v-payload)
        o-type-ref (cell/cell-ref-put v-root 0 "typed/type" i-type-root)
        o-value-ref (cell/cell-ref-put v-root 1 "typed/value" i-value-root)
        o-row (pg/t:upsert -/TypedValue
                            {:typed-root v-root
                             :type-root i-type-root
                             :value-root i-value-root})]
    (return v-root)))

(defn.pg typed-value-get
  {:added "0.5"}
  [:bytea i-typed-root]
  (return (pg/t:get -/TypedValue {:where {:typed-root i-typed-root}})))

(defn.pg ^{:- [:bytea]}
  value-type-root
  {:added "0.5"}
  [:bytea i-value-root]
  (let [o-typed (-/typed-value-get i-value-root)
        o-cell (cell/cell-by-hash i-value-root)]
    (cond [o-typed :is-not-null]
          (return (:bytea (:->> o-typed "type_root")))
          [o-cell :is-null]
          (return nil)
          :else
          (return (-/builtin-type-put (:integer (:->> o-cell "type_tag")))))))

(defn.pg ^{:- [:bytea]}
  implementation-payload
  {:added "0.5"}
  [:bytea i-protocol-root :bytea i-type-root :bytea i-methods-root]
  (return
   (pg/decode
    (|| "R:protocol-implementation:1:3:"
        (-/root-hex i-protocol-root)
        (-/root-hex i-type-root)
        (-/root-hex i-methods-root))
    "escape")))

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
                         (+ i-position 1) i-count)))))))

(defn.pg ^{:- [:boolean]}
  implementation-methods-valid
  {:added "0.5"}
  [:bytea i-protocol-root :bytea i-methods-root]
  (let [o-protocol (-/protocol-get i-protocol-root)
        o-methods (cell/cell-by-hash i-methods-root)
        _ (when (or [o-protocol :is-null] [o-methods :is-null]) (return false))
        (:bytea v-protocol-methods-root)
        (:bytea (:->> o-protocol "methods_root"))
        (:integer v-protocol-count)
        (cell/cell-ref-count v-protocol-methods-root "key")
        (:integer v-implementation-count)
        (cell/cell-ref-count i-methods-root "key")]
    (return
     (and (== (:smallint (:->> o-methods "type_tag")) 11)
          (== v-protocol-count v-implementation-count)
          (-/implementation-methods-valid-at
           v-protocol-methods-root i-methods-root 0 v-protocol-count)))))

(defn.pg ^{:- [:bytea]}
  implementation-put
  {:added "0.5"}
  [:bytea i-protocol-root :bytea i-type-root :bytea i-methods-root]
  (let [_ (pg/assert (-/protocol-valid i-protocol-root)
                     [:ledger/invalid-protocol])
        _ (pg/assert [(-/type-get i-type-root) :is-not-null]
                     [:ledger/missing-type-descriptor])
        _ (pg/assert (-/implementation-methods-valid
                      i-protocol-root i-methods-root)
                     [:ledger/invalid-protocol-implementation])
        (:bytea v-payload)
        (-/implementation-payload i-protocol-root i-type-root i-methods-root)
        (:bytea v-root) (cell/cell-put (codec/canonical-hash 14 v-payload)
                                       1 14 v-payload)
        o-protocol-ref (cell/cell-ref-put v-root 0 "implementation/protocol"
                                          i-protocol-root)
        o-type-ref (cell/cell-ref-put v-root 1 "implementation/type" i-type-root)
        o-methods-ref (cell/cell-ref-put v-root 2 "implementation/methods"
                                         i-methods-root)
        o-row (pg/t:upsert -/ProtocolImplementation
                            {:implementation-root v-root
                             :protocol-root i-protocol-root
                             :type-root i-type-root
                             :methods-root i-methods-root})]
    (return v-root)))

(defn.pg implementation-get
  {:added "0.5"}
  [:bytea i-implementation-root]
  (return (pg/t:get -/ProtocolImplementation
                    {:where {:implementation-root i-implementation-root}})))

(defn.pg ^{:- [:bytea]}
  implementation-key-root
  {:added "0.5"}
  [:bytea i-protocol-root :bytea i-type-root]
  (return
   (value/put-symbol
    (|| "ignatius.protocol.impl/"
        (-/root-hex i-protocol-root) "/"
        (-/root-hex i-type-root)))))

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
            (return (-/result-error i-context-root "invalid-protocol-implementation")))
        (:integer v-method-count) (cell/cell-ref-count i-methods-root "key")
        (:integer v-cost) (+ 4 (* 2 v-method-count))
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
        (:bytea v-state-context)
        (context/context-with-state i-context-root v-next-state)
        (:bytea v-next-context) (context/context-charge v-state-context v-cost)]
    (return (-/result-ok v-next-context v-implementation-root))))

(defn.pg ^{:- [:bytea]}
  resolve-method
  "Resolves a protocol method implementation from the supplied immutable state."
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
        o-implementation (-/implementation-get v-implementation-root)
        (:bytea v-function-root)
        (pg/case [o-implementation :is-null] nil
                 :else (value/map-get
                        (:bytea (:->> o-implementation "methods_root"))
                        i-method-name-root))]
    (return v-function-root)))

(defn.pg ^{:- [:bigint]}
  method-arity
  {:added "0.5"}
  [:bytea i-protocol-root :bytea i-method-name-root]
  (let [o-protocol (-/protocol-get i-protocol-root)
        (:bytea v-arity-root)
        (pg/case [o-protocol :is-null] nil
                 :else (value/map-get
                        (:bytea (:->> o-protocol "methods_root"))
                        i-method-name-root))]
    (return (pg/case [v-arity-root :is-null] -1
                     :else (value/integer-bigint v-arity-root)))))
