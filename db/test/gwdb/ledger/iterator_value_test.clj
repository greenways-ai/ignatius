(ns gwdb.ledger.iterator-value-test
  (:use code.test)
  (:require [tahto.core :as l]
            [postgres.core :as pg]
            [gwdb.ledger.base :as base]
            [gwdb.ledger.iterator :as iterator]
            [gwdb.ledger.value :as value]))

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
             [gwdb.ledger.iterator :as iterator]
             [gwdb.ledger.value :as value]]
   :static {:application ["gw"]
            :seed ["gw_ledger"]
            :all {:schema ["gw_ledger"]}}})

(fact:global
 {:setup [(l/rt:teardown :postgres)
          (l/rt:setup :postgres)]
  :teardown [(l/rt:teardown :postgres)
             (l/rt:stop)]})

^{:refer gwdb.ledger.iterator/iterator-step :added "0.2"}
(fact "vector iterator successors are canonical values and resume from their state root"
  (!.pg
   [:select
    (iterator/iterator-valid
     (iterator/iterator-attach
      "vector" (iterator/plan-put "vector" nil)
      (value/put-vector
       (pg/jsonb-build-array
        (pg/encode (value/put-integer "1") "hex")
        (pg/encode (value/put-integer "2") "hex")
        (pg/encode (value/put-integer "3") "hex")))
      (value/put-integer "0")))]
   [:select
    (==
     (:bytea
      (:->> (iterator/iterator-step
              (iterator/iterator-attach
               "vector" (iterator/plan-put "vector" nil)
               (value/put-vector
                (pg/jsonb-build-array
                 (pg/encode (value/put-integer "1") "hex")
                 (pg/encode (value/put-integer "2") "hex")
                 (pg/encode (value/put-integer "3") "hex")))
               (value/put-integer "0")))
             "value"))
     (value/put-integer "1"))]
   [:select
    (==
     (:bytea
      (:->> (iterator/iterator-step
              (:bytea
               (:->> (iterator/iterator-step
                       (iterator/iterator-attach
                        "vector" (iterator/plan-put "vector" nil)
                        (value/put-vector
                         (pg/jsonb-build-array
                          (pg/encode (value/put-integer "1") "hex")
                          (pg/encode (value/put-integer "2") "hex")
                          (pg/encode (value/put-integer "3") "hex")))
                        (value/put-integer "0")))
                      "next")))
             "value"))
     (value/put-integer "2"))])
  => '(true true true))
