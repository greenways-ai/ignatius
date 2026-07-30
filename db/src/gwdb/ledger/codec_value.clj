(ns gwdb.ledger.codec-value
  (:refer-clojure :exclude [compare])
  (:require [tahto.core :as l]
            [postgres.core :as pg]
            [gwdb.ledger.codec :as codec]
            [gwdb.ledger.cell :as cell]))

;; This layer deliberately follows Cell in SQL emission order.  The primitive
;; codec is dependency-free; root encoding reads an already-verified cell.
(l/script :postgres
  {:require [[postgres.core :as pg]
             [gwdb.ledger.codec :as codec]
             [gwdb.ledger.cell :as cell]]
   :config {:dbname "gw-ledger-test"}
   :import [["pgcrypto"]]
   :static {:application ["gw"]
            :all {:schema ["gw_ledger"]}}})

(defn.pg ^{:- [:bytea]} encode
  "Returns the complete Hara Canonical Value Encoding v1 bytes for a root."
  {:added "0.1"}
  [:bytea i-root]
  (let [o-cell (cell/cell-by-hash i-root)]
    (pg/assert [o-cell :is-not-null]
               [:ledger/missing-codec-cell])
    (return (codec/canonical-encode
             (:integer (:->> o-cell "type_tag"))
             (:bytea (:->> o-cell "payload"))))))

(defn.pg ^{:- [:integer]} compare
  "Compares roots by complete canonical bytes, never by digest alone."
  {:added "0.1"}
  [:bytea i-left-root :bytea i-right-root]
  (let [(:bytea v-left) (-/encode i-left-root)
        (:bytea v-right) (-/encode i-right-root)]
    (return (pg/case
             (< v-left v-right) -1
             (> v-left v-right) 1
             :else 0))))

(defn.pg ^{:- [:boolean]
           :%% :sql
           :props [:immutable :parallel-safe]}
  root-hex-valid
  "Recognises one SHA-256 root transport value without decoding JSON text."
  {:added "0.1"}
  [:text i-root-hex]
  (and (== (pg/length i-root-hex) 64)
       [(pg/regexp-match i-root-hex "^[0-9a-f]{64}$") :is-not-null]))

(defn.pg ^{:- [:bytea]} child-root-at
  "Validates and decodes one child root from constructor transport."
  {:added "0.1"}
  [:jsonb i-child-roots :integer i-position]
  (let [(:text v-child-hex) (:->> i-child-roots i-position)
        _ (pg/assert (-/root-hex-valid v-child-hex)
                     [:ledger/invalid-child-root])
        (:bytea v-child-root) (pg/decode v-child-hex "hex")
        o-child (cell/cell-by-hash v-child-root)
        _ (pg/assert [o-child :is-not-null]
                     [:ledger/missing-child-cell])]
    (return v-child-root)))

(defn.pg ^{:- [:text]} sequence-payload-tail
  "Encodes ordered child roots from a JSON array by explicit array position."
  {:added "0.1"}
  [:jsonb i-child-roots :integer i-position :integer i-count]
  (cond (>= i-position i-count)
        (return "")
        :else
        (let [(:bytea v-child-root) (-/child-root-at i-child-roots i-position)
              (:text v-child-hex) (pg/encode v-child-root "hex")
              (:text v-tail)
              (-/sequence-payload-tail i-child-roots (+ i-position 1) i-count)]
          (return (|| v-child-hex v-tail)))))

(defn.pg ^{:- [:bytea]} sequence-payload
  "Canonical payload for ordered list/vector child references.

  The JSON array is constructor transport only.  Stored bytes are `S:<count>:`
  followed by the fixed-width child roots in explicit input order."
  {:added "0.1"}
  [:jsonb i-child-roots]
  (let [(:integer v-count) (pg/jsonb-array-length i-child-roots)
        _ (pg/assert [v-count :is-not-null]
                     [:ledger/children-must-be-array])
        (:text v-prefix) (|| "S:" v-count ":")
        (:text v-tail) (-/sequence-payload-tail i-child-roots 0 v-count)]
    (return (pg/decode (|| v-prefix v-tail) "escape"))))

(defn.pg ^{:- [:boolean]} roots-strictly-ordered
  "Validates a set order using full canonical child bytes."
  {:added "0.1"}
  [:jsonb i-child-roots :integer i-position :integer i-count]
  (cond (>= (+ i-position 1) i-count)
        (return true)
        :else
        (let [(:bytea v-left) (-/child-root-at i-child-roots i-position)
              (:bytea v-right) (-/child-root-at i-child-roots (+ i-position 1))]
          (return (and (< (-/compare v-left v-right) 0)
                       (-/roots-strictly-ordered
                        i-child-roots (+ i-position 1) i-count))))))

(defn.pg ^{:- [:boolean]} map-keys-strictly-ordered
  "Validates map keys in canonical order and rejects duplicate keys."
  {:added "0.1"}
  [:jsonb i-child-roots :integer i-position :integer i-count]
  (cond (>= (+ i-position 2) i-count)
        (return true)
        :else
        (let [(:bytea v-left) (-/child-root-at i-child-roots i-position)
              (:bytea v-right) (-/child-root-at i-child-roots (+ i-position 2))]
          (return (and (< (-/compare v-left v-right) 0)
                       (-/map-keys-strictly-ordered
                        i-child-roots (+ i-position 2) i-count))))))

(defn.pg ^{:- [:bytea]} set-payload
  "Canonical set payload from roots already sorted by canonical value bytes."
  {:added "0.1"}
  [:jsonb i-child-roots]
  (let [(:integer v-count) (pg/jsonb-array-length i-child-roots)
        _ (pg/assert [v-count :is-not-null]
                     [:ledger/children-must-be-array])
        _ (pg/assert (-/roots-strictly-ordered i-child-roots 0 v-count)
                     [:ledger/unordered-set-children])
        (:text v-prefix) (|| "T:" v-count ":")
        (:text v-tail) (-/sequence-payload-tail i-child-roots 0 v-count)]
    (return (pg/decode (|| v-prefix v-tail) "escape"))))

(defn.pg ^{:- [:bytea]} map-payload
  "Canonical map payload from canonical-order key/value root pairs."
  {:added "0.1"}
  [:jsonb i-child-roots]
  (let [(:integer v-count) (pg/jsonb-array-length i-child-roots)
        _ (pg/assert [v-count :is-not-null]
                     [:ledger/children-must-be-array])
        _ (pg/assert (== (pg/mod v-count 2) 0)
                     [:ledger/uneven-map-children])
        _ (pg/assert (-/map-keys-strictly-ordered i-child-roots 0 v-count)
                     [:ledger/unordered-map-keys])
        (:text v-prefix) (|| "M:" (/ v-count 2) ":")
        (:text v-tail) (-/sequence-payload-tail i-child-roots 0 v-count)]
    (return (pg/decode (|| v-prefix v-tail) "escape"))))

(defn.pg ^{:- [:bytea]} syntax-payload
  "Canonical two-root payload for an explicit syntax wrapper."
  {:added "0.1"}
  [:bytea i-value-root :bytea i-metadata-root]
  (return (-/sequence-payload
           (pg/jsonb-build-array
            (pg/encode i-value-root "hex")
            (pg/encode i-metadata-root "hex")))))
