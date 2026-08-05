(ns gwdb.ledger.codec
  (:require [tahto.core :as l]
            [postgres.core :as pg]
            [gwdb.ledger.type :as type]))

(l/script :postgres
  {:require [[postgres.core :as pg]
             [gwdb.ledger.type :as type]]
   :config {:dbname "gw-ledger-test"}
   :import [["pgcrypto"]]
   :static {:application ["gw"]
            :seed ["gw_ledger"]
            :all {:schema ["gw_ledger"]}}})

(defn.pg ^{:- [:bytea]
           :%% :sql
           :props [:immutable :parallel-safe]}
  sha256
  "Hashes canonical bytes with the v1 prototype algorithm."
  {:added "0.1"}
  [:bytea input]
  (public.digest input "sha256"))

(defn.pg ^{:- [:boolean]
           :%% :sql
           :props [:immutable :parallel-safe]}
  hash-valid
  "Checks the fixed SHA-256 digest width."
  {:added "0.1"}
  [:bytea input]
  (== (pg/length input) 32))

(defn.pg ^{:- [:bytea]
           :%% :sql
           :props [:immutable :parallel-safe]}
  canonical-encode
  "Encodes the v1 envelope with an explicit version, tag, length, and payload."
  {:added "0.1"}
  [:integer type-tag :bytea payload]
  (pg/decode (|| "HCV1:" type-tag ":" (pg/length payload) ":"
                 (pg/encode payload "hex"))
             "escape"))

(defn.pg ^{:- [:bytea]
           :%% :sql
           :props [:immutable :parallel-safe]}
  canonical-hash
  "Hashes the v1 codec marker, type tag, and canonical payload bytes."
  {:added "0.1"}
  [:integer type-tag :bytea payload]
  (public.digest (-/canonical-encode type-tag payload)
                 "sha256"))

(defn.pg ^{:- [:boolean]
           :%% :sql
           :props [:immutable :parallel-safe]}
  valid-type-tag
  "Checks the closed initial Hara tag set."
  {:added "0.1"}
  [:integer type-tag]
  (and (>= type-tag 0)
       (<= type-tag 20)))

(defn.pg ^{:- [:boolean]
           :props [:immutable :parallel-safe]}
  framed-roots-valid
  "Checks a canonical root-reference payload without reading projections."
  {:added "0.1"}
  [:bytea i-payload :text i-kind :integer i-roots-per-count]
  (let [(:text v-text) (pg/encode i-payload "escape")
        (:text v-count-text) (pg/split-part v-text ":" 2)
        (:text v-roots) (pg/split-part v-text ":" 3)]
    (return
     (pg/case
      [(pg/regexp-match
        v-text
        (|| "^" i-kind ":(0|[1-9][0-9]*):[0-9a-f]*$")) :is-not-null]
      (== (pg/length v-roots)
          (* (:bigint v-count-text) 64 i-roots-per-count))
      :else false))))

(defn.pg ^{:- [:boolean]
           :%% :sql
           :props [:immutable :parallel-safe]}
  payload-valid
  "Checks the v1 primitive payload envelopes before hashing a cell."
  {:added "0.1"}
  [:integer i-type-tag :bytea i-payload]
  (pg/case
   (== i-type-tag 0)
   (== (pg/length i-payload) 0)
   (== i-type-tag 1)
   (or (== i-payload (pg/decode "00" "hex"))
       (== i-payload (pg/decode "01" "hex")))
   (== i-type-tag 2)
   [(pg/regexp-match (pg/encode i-payload "escape")
                     "^-?(0|[1-9][0-9]*)$") :is-not-null]
   (== i-type-tag 3)
   (== (pg/length i-payload) 8)
   (or (== i-type-tag 9) (== i-type-tag 10))
   (-/framed-roots-valid i-payload "S" 1)
   (== i-type-tag 11)
   (-/framed-roots-valid i-payload "M" 2)
   (== i-type-tag 12)
   (-/framed-roots-valid i-payload "T" 1)
   (== i-type-tag 13)
   (and (-/framed-roots-valid i-payload "S" 1)
        (== (:bigint (pg/split-part (pg/encode i-payload "escape") ":" 2)) 2))
   :else
   true))

(defn.pg ^{:- [:boolean]
           :%% :sql
           :props [:immutable :parallel-safe]}
  verify
  "Verifies a cell hash against its type tag and canonical payload."
  {:added "0.1"}
  [:bytea i-hash :integer i-type-tag :bytea i-payload]
  (and (-/hash-valid i-hash)
       (-/valid-type-tag i-type-tag)
       (-/payload-valid i-type-tag i-payload)
       (== i-hash (-/canonical-hash i-type-tag i-payload))))
