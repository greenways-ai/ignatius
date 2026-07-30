(ns gwdb.ledger.developer-test
  (:use code.test)
  (:require [tahto.core :as l]
            [postgres.core :as pg]
            [gwdb.ledger.base :as base]
            [gwdb.ledger.developer :as developer]))

(l/script- :postgres
  {:runtime :jdbc.client
   :config {:dbname "gw-ledger-test"
            :temp :create
            :container {:group "gw-ledger"
                        :image "gw-ledger-postgres:15-pgsodium"
                        :ports [5432]
                        :environment {"POSTGRES_PASSWORD" "postgres"
                                      "POSTGRES_USER" "postgres"}
                        :cmd ["postgres"]}}
   :require [[postgres.core :as pg]
             [gwdb.ledger.base :as base :primary true]
             [gwdb.ledger.developer :as developer]]
   :static {:application ["gw"]
            :seed ["gw_ledger"]
            :all {:schema ["gw_ledger"]}}})

(fact:global
 {:setup [(l/rt:teardown :postgres)
          (l/rt:setup :postgres)]
  :teardown [(l/rt:teardown :postgres)
             (l/rt:stop)]})

^{:refer gwdb.ledger.developer/developer-submit-integer :added "0.3"}
(fact "the unsigned developer flow creates genesis, an account, and a receipt"
  (!.pg
   [:select (pg/length (developer/developer-genesis "devnet" 0))]
   [:select (pg/jsonb-extract-path-text
             (developer/developer-create-account "devnet" "alice" 1)
             "address")]
   [:select (pg/jsonb-extract-path-text
             (developer/developer-submit-integer "devnet" "alice" "7" 10 2)
             "status")]
   [:select (pg/jsonb-extract-path-text (developer/developer-head "devnet") "height")])
  => '(32 "alice" "ok" 2))
