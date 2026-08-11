(ns gwdb.ledger.codec-test
  (:use code.test)
  (:require [tahto.core :as l]
            [postgres.core :as pg]
            [gwdb.ledger.base :as base]
            [gwdb.ledger.codec :as codec]))

(l/script- :postgres
  {:runtime :jdbc.client
   :config {:dbname "gw-ledger-test"
            :temp :create
            :vendor :impossibl
            :container {:group "gw-ledger"
                        :image "gw-ledger-postgres:15-pgsodium"
                        :ports [5432]
                        :environment {"POSTGRES_PASSWORD" "postgres"
                                      "POSTGRES_USER" "postgres"}
                        :cmd ["postgres"]}}
   :require [[postgres.core :as pg]
             [gwdb.ledger.base :as base :primary true]
             [gwdb.ledger.codec :as codec]]
   :static {:application ["gw"]
            :seed ["gw_ledger"]
            :all {:schema ["gw_ledger"]}}})

(fact:global
 {:setup [(l/rt:teardown :postgres)
          (l/rt:setup :postgres)]
  :teardown [(l/rt:teardown :postgres)
             (l/rt:stop)]})

^{:refer gwdb.ledger.codec/sha256 :added "0.1"}
(fact "SHA-256 is explicit and has the expected fixed digest"
  (!.pg
   [:select (pg/encode (codec/sha256 (pg/decode "hello" "escape")) "hex")]
   [:select (codec/hash-valid (codec/sha256 (pg/decode "hello" "escape")))]
   [:select (codec/hash-valid (pg/decode "00" "hex"))])
  => '("2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824" true false))

^{:refer gwdb.ledger.codec/compare :added "0.12"}
(fact "canonical byte strings have a deterministic total order"
  (!.pg
   [:select (codec/compare (pg/decode "00" "hex")
                           (pg/decode "01" "hex"))]
   [:select (codec/compare (pg/decode "01" "hex")
                           (pg/decode "01" "hex"))]
   [:select (codec/compare (pg/decode "ff" "hex")
                           (pg/decode "01" "hex"))])
  => '(-1 0 1))

^{:refer gwdb.ledger.codec/canonical-encode :added "0.1"}
(fact "canonical envelopes commit version, tag, payload length, and bytes"
  (!.pg
   [:select (pg/encode (codec/canonical-encode 5 (pg/decode "hello" "escape")) "escape")]
   [:select (pg/encode (codec/canonical-hash 5 (pg/decode "hello" "escape")) "hex")]
   [:select (codec/verify
             (codec/canonical-hash 5 (pg/decode "hello" "escape"))
             5 (pg/decode "hello" "escape"))])
  => '("HCV0:5:5:68656c6c6f"
      "7fa243b5c27ab4e7661a6207f8ad5ca4ce68d4ad6c224b09d050db4ce09d6d3b"
      true))

^{:refer gwdb.ledger.codec/valid-type-tag :added "0.1"}
(fact "the closed protocol tag range and primitive payload rules reject ambiguity"
  (!.pg
   [:select (codec/valid-type-tag 0)]
   [:select (codec/valid-type-tag 20)]
   [:select (codec/valid-type-tag 21)]
   [:select (codec/payload-valid 1 (pg/decode "01" "hex"))]
   [:select (codec/payload-valid 1 (pg/decode "02" "hex"))]
   [:select (codec/payload-valid 2 (pg/decode "01" "escape"))]
   [:select (codec/payload-valid 2 (pg/decode "1" "escape"))])
  => '(true true false true false false true))

^{:refer gwdb.ledger.codec/framed-roots-valid :added "0.1"}
(fact "compound payload framing validates declared roots instead of JSON text"
  (!.pg
   [:select (codec/framed-roots-valid
             (pg/decode "S:1:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "escape")
             "S" 1)]
   [:select (codec/framed-roots-valid (pg/decode "S:1:aa" "escape") "S" 1)]
   [:select (codec/payload-valid 9
             (pg/decode "S:1:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "escape"))])
  => '(true false true))
