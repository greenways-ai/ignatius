(ns gwdb.ledger.runtime-support
  (:require [tahto.core :as l]
            [postgres.core :as pg]
            [gwdb.ledger.cell :as cell]
            [gwdb.ledger.context :as context]
            [gwdb.ledger.runtime :as runtime]
            [gwdb.ledger.value :as value]))

(l/script :postgres
  {:require [[postgres.core :as pg]
             [gwdb.ledger.cell :as cell]
             [gwdb.ledger.context :as context]
             [gwdb.ledger.runtime :as runtime]
             [gwdb.ledger.value :as value]]
   :config {:dbname "gw-ledger-test"}
   :static {:application ["gw"]
            :all {:schema ["gw_ledger"]}}})

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
  apply-vector-count
  {:added "0.7"}
  [:bytea i-context-root :jsonb i-roots]
  (let [(:bytea v-input-root) (-/root-at i-roots 0)
        o-input (cell/cell-by-hash v-input-root)
        _ (when (or [o-input :is-null]
                    (not (== (:smallint (:->> o-input "type_tag")) 10)))
            (return (runtime/result-error i-context-root "vector-required")))
        (:bytea v-result-root)
        (value/put-integer-number
         (cell/cell-ref-count v-input-root "element"))]
    (return
     (runtime/result-ok
      (context/context-charge i-context-root 1) v-result-root))))

(defn.pg ^{:- [:jsonb]}
  apply-vector-get
  {:added "0.7"}
  [:bytea i-context-root :jsonb i-roots]
  (let [(:bytea v-input-root) (-/root-at i-roots 0)
        (:bytea v-index-root) (-/root-at i-roots 1)
        o-input (cell/cell-by-hash v-input-root)
        _ (when (or [o-input :is-null]
                    (not (== (:smallint (:->> o-input "type_tag")) 10))
                    (not (-/integer-root v-index-root)))
            (return (runtime/result-error i-context-root
                                          "vector-and-index-required")))
        (:integer v-index) (:integer (value/integer-bigint v-index-root))
        (:bytea v-found-root) (value/vector-get v-input-root v-index)
        (:bytea v-result-root)
        (pg/case [v-found-root :is-null]
                 (value/put-nil)
                 :else v-found-root)]
    (return
     (runtime/result-ok
      (context/context-charge i-context-root 1) v-result-root))))

(defn.pg ^{:- [:jsonb]}
  apply-map-new
  {:added "0.7"}
  [:bytea i-context-root :jsonb i-roots]
  (let [(:integer v-count) (pg/jsonb-array-length i-roots)
        _ (when (not (== (pg/mod v-count 2) 0))
            (return (runtime/result-error i-context-root "map-even-arity")))
        (:bytea v-result-root)
        (-/map-from-roots-at
         i-roots 0 v-count (value/put-map (pg/jsonb-build-array)))]
    (return
     (runtime/result-ok
      (context/context-charge i-context-root 1) v-result-root))))

(defn.pg ^{:- [:jsonb]}
  apply-map-get
  {:added "0.7"}
  [:bytea i-context-root :jsonb i-roots]
  (let [(:bytea v-input-root) (-/root-at i-roots 0)
        o-input (cell/cell-by-hash v-input-root)
        _ (when (or [o-input :is-null]
                    (not (== (:smallint (:->> o-input "type_tag")) 11)))
            (return (runtime/result-error i-context-root "map-required")))
        (:bytea v-found-root)
        (value/map-get v-input-root (-/root-at i-roots 1))
        (:bytea v-result-root)
        (pg/case [v-found-root :is-null]
                 (value/put-nil)
                 :else v-found-root)]
    (return
     (runtime/result-ok
      (context/context-charge i-context-root 1) v-result-root))))

(defn.pg ^{:- [:jsonb]}
  apply-map-assoc
  {:added "0.7"}
  [:bytea i-context-root :jsonb i-roots]
  (let [(:bytea v-input-root) (-/root-at i-roots 0)
        o-input (cell/cell-by-hash v-input-root)
        _ (when (or [o-input :is-null]
                    (not (== (:smallint (:->> o-input "type_tag")) 11)))
            (return (runtime/result-error i-context-root "map-required")))
        (:bytea v-result-root)
        (value/map-assoc v-input-root
                         (-/root-at i-roots 1)
                         (-/root-at i-roots 2))]
    (return
     (runtime/result-ok
      (context/context-charge i-context-root 1) v-result-root))))

(defn.pg ^{:- [:jsonb]}
  apply-string-concat
  {:added "0.7"}
  [:bytea i-context-root :jsonb i-roots]
  (let [(:text v-result-text)
        (-/string-concat-at
         i-roots 0 (pg/jsonb-array-length i-roots) "")
        _ (when [v-result-text :is-null]
            (return (runtime/result-error i-context-root "string-required")))
        (:bytea v-result-root) (value/put-string v-result-text)]
    (return
     (runtime/result-ok
      (context/context-charge i-context-root 1) v-result-root))))

(defn.pg ^{:- [:jsonb]}
  apply-primitive
  "Applies a primitive to already evaluated canonical roots."
  {:added "0.7"}
  [:bytea i-context-root :text i-primitive-id :jsonb i-roots]
  (let [_ (when (not (context/context-can-charge i-context-root 1))
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
          (return (-/apply-vector-count i-context-root i-roots))

          (== i-primitive-id "vector/get")
          (return (-/apply-vector-get i-context-root i-roots))

          (== i-primitive-id "map/new")
          (return (-/apply-map-new i-context-root i-roots))

          (== i-primitive-id "map/get")
          (return (-/apply-map-get i-context-root i-roots))

          (== i-primitive-id "map/assoc")
          (return (-/apply-map-assoc i-context-root i-roots))

          (== i-primitive-id "string/concat")
          (return (-/apply-string-concat i-context-root i-roots))

          :else
          (return (runtime/result-error i-context-root "unknown-primitive")))))