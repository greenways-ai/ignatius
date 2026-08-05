(ns gwdb.ledger.integrity-test
  (:use code.test)
  (:require [tahto.core :as l]
            [postgres.core :as pg]
            [gwdb.ledger.base :as base]
            [gwdb.ledger.account :as account]
            [gwdb.ledger.block :as block]
            [gwdb.ledger.integrity :as integrity]
            [gwdb.ledger.module :as module]
            [gwdb.ledger.state :as state]
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
             [gwdb.ledger.account :as account]
             [gwdb.ledger.block :as block]
             [gwdb.ledger.integrity :as integrity]
             [gwdb.ledger.module :as module]
             [gwdb.ledger.state :as state]
             [gwdb.ledger.value :as value]]
   :static {:application ["gw"]
            :seed ["gw_ledger"]
            :all {:schema ["gw_ledger"]}}})

(fact:global
 {:setup [(l/rt:teardown :postgres)
          (l/rt:setup :postgres)]
  :teardown [(l/rt:teardown :postgres)
             (l/rt:stop)]})

^{:refer gwdb.ledger.integrity/block-integrity :added "0.2"}
(fact "integrity checks traverse a canonical block, state and committed child cells"
  (!.pg
   [:select
    (integrity/block-integrity
     (block/block-put
      "othernet" 0 nil
      (state/state-genesis) (state/state-genesis) 0
      (value/put-symbol "proposer") nil (pg/jsonb-build-array)))])
  => true)

^{:refer gwdb.ledger.integrity/rebuild-account-projection :added "0.2"}
(fact "account projection rebuild reads only the authoritative state accounts map"
  (!.pg
   [:select
    (:->> (integrity/rebuild-account-projection
            (state/state-assoc-account
             (state/state-genesis)
             (value/put-symbol "address")
             (account/account-value-create (value/put-nil)) 0)
            (value/put-symbol "address"))
           "sequence")]
   [:select
    [(:->> (account/account-get (value/put-symbol "address")) "state_root") :is-not-null]])
  => '(0 true))

^{:refer gwdb.ledger.integrity/rebuild-module-export-projection :added "0.2"}
(fact "module export projection rebuild follows the immutable export set"
  (!.pg
   [:select
    (:->>
     (module/module-export-projection-get
      (module/module-publish
       "std.integrity" "1.0.0"
       (value/put-map
        (pg/jsonb-build-array
         (pg/encode (value/put-symbol "answer") "hex")
         (pg/encode (value/put-integer "42") "hex")))
       (value/put-set
        (pg/jsonb-build-array
         (pg/encode (value/put-symbol "answer") "hex")))
       (value/put-map (pg/jsonb-build-array)) nil nil
       (value/put-map (pg/jsonb-build-array))
       (value/put-symbol "publisher") nil)
      (value/put-symbol "answer"))
     "value_root")]
   [:select
    (integrity/rebuild-module-export-projection
     (module/module-publish
      "std.integrity" "1.0.0"
      (value/put-map
       (pg/jsonb-build-array
        (pg/encode (value/put-symbol "answer") "hex")
        (pg/encode (value/put-integer "42") "hex")))
      (value/put-set
       (pg/jsonb-build-array
        (pg/encode (value/put-symbol "answer") "hex")))
      (value/put-map (pg/jsonb-build-array)) nil nil
      (value/put-map (pg/jsonb-build-array))
      (value/put-symbol "publisher") nil))]
   [:select
    (==
     (:bytea
      (:->>
       (module/module-export-projection-get
        (module/module-publish
         "std.integrity" "1.0.0"
         (value/put-map
          (pg/jsonb-build-array
           (pg/encode (value/put-symbol "answer") "hex")
           (pg/encode (value/put-integer "42") "hex")))
         (value/put-set
          (pg/jsonb-build-array
           (pg/encode (value/put-symbol "answer") "hex")))
         (value/put-map (pg/jsonb-build-array)) nil nil
         (value/put-map (pg/jsonb-build-array))
         (value/put-symbol "publisher") nil)
        (value/put-symbol "answer"))
       "value_root"))
     (value/put-integer "42"))])
  => '(nil true true))


^{:refer gwdb.ledger.integrity/cell-integrity :added "0.1"}
(fact "TODO")

^{:refer gwdb.ledger.integrity/state-integrity :added "0.1"}
(fact "TODO")

^{:refer gwdb.ledger.integrity/head-integrity :added "0.1"}
(fact "TODO")

^{:refer gwdb.ledger.integrity/rebuild-module-export-projection-at :added "0.1"}
(fact "TODO")