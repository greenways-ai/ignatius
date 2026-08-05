(ns gwdb.ledger.syntax
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

(deftype.pg Syntax
  "Derived index for the explicit syntax wrapper value."
  {:added "0.1"}
  [:syntax-root {:type :bytea :primary true}
   :value-root  {:type :bytea :required true}
   :metadata-root {:type :bytea :required true}])

(defn.pg ^{:- [:bytea]} put-syntax
  "Stores a syntax wrapper and records its two child roots."
  {:added "0.1"}
  [:bytea i-value-root
   :bytea i-metadata-root]
  (let [o-value (cell/cell-by-hash i-value-root)
        o-metadata (cell/cell-by-hash i-metadata-root)
        _ (pg/assert [o-value :is-not-null]
                     [:ledger/missing-syntax-value])
        _ (pg/assert [o-metadata :is-not-null]
                     [:ledger/missing-syntax-metadata])
        _ (pg/assert (== (:smallint (:->> o-metadata "type_tag")) 11)
                     [:ledger/syntax-metadata-not-map])
        (:bytea v-payload) (codec-value/syntax-payload
                             i-value-root i-metadata-root)
        (:bytea o-root) (cell/cell-put (codec/canonical-hash 13 v-payload)
                              1 13 v-payload)
        o-value-ref (cell/cell-ref-put o-root 0 "value" i-value-root)
        o-metadata-ref (cell/cell-ref-put o-root 1 "metadata" i-metadata-root)
        o-upsert (pg/t:upsert -/Syntax
                       {:syntax-root o-root
                        :value-root i-value-root
                        :metadata-root i-metadata-root})]
    (return o-root)))

(defn.pg ^{:- [:bytea]} syntax-value-root
  "Returns the semantic value root from an outer syntax wrapper."
  {:added "0.1"}
  [:bytea i-syntax-root]
  (let [o-row (pg/t:get -/Syntax
                        {:where {:syntax-root i-syntax-root}})]
    (return (:bytea (:->> o-row "value_root")))))

(defn.pg ^{:- [:bytea]} syntax-metadata-root
  "Returns the explicit metadata root from an outer syntax wrapper."
  {:added "0.1"}
  [:bytea i-syntax-root]
  (let [o-row (pg/t:get -/Syntax
                        {:where {:syntax-root i-syntax-root}})]
    (return (:bytea (:->> o-row "metadata_root")))))

(defn.pg ^{:- [:bytea]} semantic-root
  "Unwraps only the outer syntax cell. Nested syntax remains data."
  {:added "0.1"}
  [:bytea i-root]
  (let [o-cell (cell/cell-by-hash i-root)]
    (cond (and [o-cell :is-not-null]
               (== (:smallint (:->> o-cell "type_tag")) 13))
          (return (-/syntax-value-root i-root))
          :else
          (return i-root))))
