(ns gwdb.ledger.crypto-test
  (:use code.test)
  (:require [tahto.core :as l]
            [postgres.core :as pg]
            [gwdb.ledger.base :as base]
            [gwdb.ledger.crypto :as crypto]
            [gwdb.ledger.value :as value]))

(l/script- :postgres
  {:runtime :jdbc.client
   :config {:dbname "gw-ledger-test"
            :temp :create
            ;; The standard temporary-container runtime retries the
            ;; impossibl JDBC startup exception while PostgreSQL initializes.
            :vendor :impossibl
            :container {:group "gw-ledger"
                        :image "gw-ledger-postgres:15-pgsodium"
                        :ports [5432]
                        :environment {"POSTGRES_PASSWORD" "postgres"
                                      "POSTGRES_USER" "postgres"}
                        :cmd ["postgres"]}}
   :require [[postgres.core :as pg]
             [gwdb.ledger.base :as base :primary true]
             [gwdb.ledger.crypto :as crypto]
             [gwdb.ledger.value :as value]]
   :static {:application ["gw"]
            :seed ["gw_ledger"]
            :all {:schema ["gw_ledger"]}}})

(fact:global
 {:setup [(l/rt:teardown :postgres)
          (l/rt:setup :postgres)]
  :teardown [(l/rt:teardown :postgres)
             (l/rt:stop)]})

^{:refer gwdb.ledger.crypto/signature-verify :added "0.3"}
(fact "the RFC 8032 Ed25519 empty-message vector verifies in PostgreSQL"
  (!.pg
   [:select
    (crypto/signature-verify
     (pg/decode "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b" "hex")
     (pg/decode "" "hex")
     (pg/decode "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a" "hex"))]
   [:select
    (crypto/public-key-root-valid
     (value/put-blob
      (pg/decode "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a" "hex")))])
  => '(true true))
