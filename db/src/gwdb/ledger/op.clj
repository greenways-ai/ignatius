(ns gwdb.ledger.op
  (:require [tahto.core :as l]
            [postgres.core :as pg]
            [gwdb.ledger.cell :as cell]
            [gwdb.ledger.codec :as codec]
            [gwdb.ledger.codec-value :as codec-value]))

(l/script :postgres
  {:require [[postgres.core :as pg]
             [gwdb.ledger.cell :as cell]
             [gwdb.ledger.codec :as codec]
             [gwdb.ledger.codec-value :as codec-value]]
   :config {:dbname "gw-ledger-test"}
   :import [["pgcrypto"]]
   :static {:application ["gw"]
            :all {:schema ["gw_ledger"]}}})

(deftype.pg Op
  "Rebuildable descriptor for an authoritative HCV0 operation cell."
  {:added "0.2"}
  [:op-root        {:type :bytea :primary true}
   :op-kind        {:type :text :required true}
   :value-root     {:type :bytea}
   :symbol-root    {:type :bytea}
   :local-depth    {:type :integer}
   :local-index    {:type :integer}
   :function-root  {:type :bytea}
   :parameter-root {:type :bytea}
   :body-root      {:type :bytea}])

(deftype.pg OpChild
  "Rebuildable ordered operation-child index committed by the parent payload."
  {:added "0.2"}
  [:op-root    {:type :bytea :primary true}
   :position   {:type :integer :primary true}
   :child-root {:type :bytea :required true}])

(defn.pg ^{:- [:boolean]
           :%% :sql
           :props [:immutable :parallel-safe]}
  op-kind-valid
  "The v1 VM has a deliberately closed operation vocabulary."
  {:added "0.2"}
  [:text i-op-kind]
  (or (== i-op-kind "constant")
      (== i-op-kind "local")
      (== i-op-kind "lookup")
      (== i-op-kind "invoke")
      (== i-op-kind "lambda")
      (== i-op-kind "do")
      (== i-op-kind "cond")
      (== i-op-kind "let")
      (== i-op-kind "def")
      (== i-op-kind "special")))

(defn.pg ^{:- [:text]}
  op-root-hex
  "Renders a nullable descriptor root with an unambiguous protocol sentinel."
  {:added "0.2"}
  [:bytea i-root]
  (return (pg/case [i-root :is-null] "-"
                   :else (pg/encode i-root "hex"))))

(defn.pg ^{:- [:bytea]}
  op-payload
  "Builds HCV0 operation payload bytes from every semantic descriptor field.

   Child operations use the ordinary ordered sequence encoding after the fixed
   descriptor header.  The JSON array is constructor transport only."
  {:added "0.2"}
  [:text i-op-kind
   :bytea i-value-root
   :bytea i-symbol-root
   :integer i-local-depth
   :integer i-local-index
   :bytea i-function-root
   :bytea i-parameter-root
   :bytea i-body-root
   :jsonb i-child-roots]
  (let [(:integer v-child-count) (pg/jsonb-array-length i-child-roots)
        _ (pg/assert [v-child-count :is-not-null]
                     [:ledger/op-children-must-be-array])
        (:text v-prefix)
        (|| "O:1:" i-op-kind ":"
            (-/op-root-hex i-value-root) ":"
            (-/op-root-hex i-symbol-root) ":"
            (pg/case [i-local-depth :is-null] "-" :else (:text i-local-depth)) ":"
            (pg/case [i-local-index :is-null] "-" :else (:text i-local-index)) ":"
            (-/op-root-hex i-function-root) ":"
            (-/op-root-hex i-parameter-root) ":"
            (-/op-root-hex i-body-root) ":")
        (:bytea v-children) (codec-value/sequence-payload i-child-roots)]
    (return (|| (pg/decode v-prefix "escape") v-children))))

(defn.pg op-children-put
  "Writes verified ordered child references and the matching derived index."
  {:added "0.2"}
  [:bytea i-op-root :jsonb i-child-roots :integer i-position :integer i-count]
  (cond (>= i-position i-count)
        (return nil)
        :else
        (let [(:bytea v-child-root) (codec-value/child-root-at i-child-roots i-position)
              o-ref (cell/cell-ref-put i-op-root i-position "op-child" v-child-root)
              o-row (pg/t:upsert -/OpChild
                                  {:op-root i-op-root
                                   :position i-position
                                   :child-root v-child-root})
              o-next (-/op-children-put i-op-root i-child-roots (+ i-position 1) i-count)]
          (return o-row))))

(defn.pg ^{:- [:bytea]} put-op
  "Stores one complete canonical operation graph node.

   No caller supplies pre-hashed payload bytes: all identity-affecting fields
   and child roots are encoded here before the immutable cell is inserted."
  {:added "0.2"}
  [:text i-op-kind
   :bytea i-value-root
   :bytea i-symbol-root
   :integer i-local-depth
   :integer i-local-index
   :bytea i-function-root
   :bytea i-parameter-root
   :bytea i-body-root
   :jsonb i-child-roots]
  (let [_ (pg/assert (-/op-kind-valid i-op-kind)
                     [:ledger/unknown-op i-op-kind])
        (:integer v-count) (pg/jsonb-array-length i-child-roots)
        (:bytea v-payload) (-/op-payload i-op-kind i-value-root i-symbol-root
                                         i-local-depth i-local-index i-function-root
                                         i-parameter-root i-body-root i-child-roots)
        (:bytea v-root) (cell/cell-put (codec/canonical-hash 17 v-payload)
                                        1 17 v-payload)
        o-upsert (pg/t:upsert -/Op
                               {:op-root v-root
                                :op-kind i-op-kind
                                :value-root i-value-root
                                :symbol-root i-symbol-root
                                :local-depth i-local-depth
                                :local-index i-local-index
                                :function-root i-function-root
                                :parameter-root i-parameter-root
                                :body-root i-body-root})
        o-children (-/op-children-put v-root i-child-roots 0 v-count)]
    (return v-root)))

(defn.pg ^{:- [:bytea]} constant
  {:added "0.2"}
  [:bytea i-value-root]
  (return (-/put-op "constant" i-value-root nil nil nil nil nil nil
                    (pg/jsonb-build-array))))

(defn.pg ^{:- [:bytea]} local
  {:added "0.2"}
  [:integer i-depth :integer i-index]
  (let [_ (pg/assert (and (>= i-depth 0) (>= i-index 0))
                     [:ledger/invalid-local-address])]
    (return (-/put-op "local" nil nil i-depth i-index nil nil nil
                      (pg/jsonb-build-array)))))

(defn.pg ^{:- [:bytea]} lookup
  {:added "0.2"}
  [:bytea i-symbol-root]
  (let [_ (pg/assert (== (cell/cell-type-tag i-symbol-root) 7)
                     [:ledger/lookup-requires-symbol])]
    (return (-/put-op "lookup" nil i-symbol-root nil nil nil nil nil
                      (pg/jsonb-build-array)))))

(defn.pg ^{:- [:bytea]} invoke
  {:added "0.2"}
  [:bytea i-function-root :jsonb i-argument-roots]
  (return (-/put-op "invoke" nil nil nil nil i-function-root nil nil
                    i-argument-roots)))

(defn.pg ^{:- [:bytea]} do-op
  {:added "0.2"}
  [:jsonb i-child-roots]
  (return (-/put-op "do" nil nil nil nil nil nil nil i-child-roots)))

(defn.pg ^{:- [:bytea]} cond-op
  "Creates an ordered condition/body operation-pair sequence."
  {:added "0.2"}
  [:jsonb i-child-roots]
  (return (-/put-op "cond" nil nil nil nil nil nil nil i-child-roots)))

(defn.pg ^{:- [:bytea]} def-op
  "Defines a persistent account binding from one value-producing child op."
  {:added "0.2"}
  [:bytea i-symbol-root :bytea i-value-op-root]
  (let [_ (pg/assert (== (cell/cell-type-tag i-symbol-root) 7)
                     [:ledger/def-requires-symbol])]
    (return (-/put-op "def" nil i-symbol-root nil nil nil nil nil
                      (pg/jsonb-build-array
                       (pg/encode i-value-op-root "hex"))))))

(defn.pg ^{:- [:bytea]} let-op
  "Creates a one-binding lexical let; bodies remain ordinary operation roots."
  {:added "0.2"}
  [:bytea i-symbol-root :bytea i-binding-op-root :bytea i-body-op-root]
  (let [_ (pg/assert (== (cell/cell-type-tag i-symbol-root) 7)
                     [:ledger/let-requires-symbol])]
    (return (-/put-op "let" nil i-symbol-root nil nil nil nil nil
                      (pg/jsonb-build-array
                       (pg/encode i-binding-op-root "hex")
                       (pg/encode i-body-op-root "hex"))))))

(defn.pg ^{:- [:bytea]} lambda-op
  "Builds a compiled lambda operation from parameter vector and body operation."
  {:added "0.2"}
  [:bytea i-parameters-root :bytea i-body-op-root]
  (let [_ (pg/assert (== (cell/cell-type-tag i-parameters-root) 10)
                     [:ledger/lambda-parameters-not-vector])
        _ (pg/assert (== (cell/cell-type-tag i-body-op-root) 17)
                     [:ledger/lambda-body-not-operation])]
    (return (-/put-op "lambda" nil nil nil nil nil i-parameters-root
                      i-body-op-root (pg/jsonb-build-array)))))

(defn.pg op-get
  "Returns a derived operation descriptor by immutable root."
  {:added "0.2"}
  [:bytea i-op-root]
  (let [o-row (pg/t:get -/Op {:where {:op-root i-op-root}})]
    (return o-row)))

(defn.pg ^{:- [:bytea]} op-child-root
  "Reads an ordered child committed by the parent operation cell."
  {:added "0.2"}
  [:bytea i-op-root :integer i-position]
  (return (cell/cell-ref-child i-op-root i-position "op-child")))

(defn.pg ^{:- [:jsonb]} op-child-roots
  "Reconstitutes ordered child-root constructor transport from CellRef only."
  {:added "0.2"}
  [:bytea i-op-root :integer i-position :integer i-count :jsonb i-out]
  (cond (>= i-position i-count)
        (return i-out)
        :else
        (let [(:bytea v-child-root) (-/op-child-root i-op-root i-position)
              (:jsonb v-next) (|| i-out
                                  (pg/jsonb-build-array
                                   (pg/encode v-child-root "hex")))]
          (return (-/op-child-roots i-op-root (+ i-position 1) i-count v-next)))))

(defn.pg ^{:- [:boolean]}
  op-valid
  "Checks the authoritative type and exact canonical descriptor payload."
  {:added "0.2"}
  [:bytea i-op-root]
  (let [o-cell (cell/cell-by-hash i-op-root)
        o-op (-/op-get i-op-root)
        _ (when (or [o-cell :is-null] [o-op :is-null])
            (return false))
        (:integer v-count) (cell/cell-ref-count i-op-root "op-child")
        ;; `OpChild` is a projection, so canonical reconstruction uses CellRef
        ;; rather than trusting the projection for identity.
        (:jsonb v-children) (-/op-child-roots
                              i-op-root 0 v-count
                              (pg/jsonb-build-array))
        (:bytea v-payload)
        (-/op-payload
         (:text (:->> o-op "op_kind"))
         (:bytea (:->> o-op "value_root"))
         (:bytea (:->> o-op "symbol_root"))
         (:integer (:->> o-op "local_depth"))
         (:integer (:->> o-op "local_index"))
         (:bytea (:->> o-op "function_root"))
         (:bytea (:->> o-op "parameter_root"))
         (:bytea (:->> o-op "body_root"))
         v-children)
        (:boolean v-valid)
        (and (== (:smallint (:->> o-cell "type_tag")) 17)
             (-/op-kind-valid (:text (:->> o-op "op_kind")))
             (== (:bytea (:->> o-cell "payload")) v-payload)
             (codec/verify i-op-root 17 v-payload))]
    (return v-valid)))
