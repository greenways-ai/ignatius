(ns gwdb.ledger.block-value-test
  (:use code.test)
  (:require [tahto.core :as l]
            [postgres.core :as pg]
            [gwdb.ledger.base :as base]
            [gwdb.ledger.account :as account]
            [gwdb.ledger.block :as block]
            [gwdb.ledger.cell :as cell]
            [gwdb.ledger.op :as op]
            [gwdb.ledger.state :as state]
            [gwdb.ledger.transaction :as transaction]
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
             [gwdb.ledger.cell :as cell]
             [gwdb.ledger.op :as op]
             [gwdb.ledger.state :as state]
             [gwdb.ledger.transaction :as transaction]
             [gwdb.ledger.value :as value]]
   :static {:application ["gw"]
            :seed ["gw_ledger"]
            :all {:schema ["gw_ledger"]}}})

(fact:global
 {:setup [(l/rt:teardown :postgres)
          (l/rt:setup :postgres)]
  :teardown [(l/rt:teardown :postgres)
             (l/rt:stop)]})

^{:refer gwdb.ledger.block/block-commit :added "0.2"}
(fact "genesis block commits canonical state and ordered empty transaction sequence"
  (!.pg
   [:select
    (block/block-valid
     (block/block-commit
      "testnet" -1 nil 0 nil
      (state/state-genesis) (state/state-genesis) 0
      (value/put-symbol "proposer") nil (pg/jsonb-build-array)))]
   [:select
    (:->> (block/head-get "testnet") "height")]
   [:select
    (cell/cell-ref-count
     (block/block-commit
      "othernet" -1 nil 0 nil
      (state/state-genesis) (state/state-genesis) 0
      (value/put-symbol "proposer") nil (pg/jsonb-build-array))
     "transaction")])
  => '(true 0 0))

^{:refer gwdb.ledger.block/block-commit-one :added "0.2"}
(fact "single-transaction block execution binds its canonical receipt to committed order"
  (!.pg
   [:select
    (block/block-valid
     (block/block-commit-one
      "execnet" -1 nil 0 nil
      (state/state-assoc-account
       (state/state-genesis)
       (value/put-symbol "address")
       (account/account-value-create (value/put-nil)) 0)
      (state/state-advance-account-sequence
       (state/state-assoc-account
        (state/state-genesis)
        (value/put-symbol "address")
        (account/account-value-create (value/put-nil)) 0)
       (value/put-symbol "address") 0)
      0 (value/put-symbol "proposer") nil
      (transaction/transaction-put
       "execnet" (value/put-symbol "address") 0
       (op/constant (value/put-integer "7")) nil 10
       (value/put-integer "1") nil)))]
   [:select
    (cell/cell-ref-count
     (block/block-commit-one
      "otherexec" -1 nil 0 nil
      (state/state-assoc-account
       (state/state-genesis)
       (value/put-symbol "address")
       (account/account-value-create (value/put-nil)) 0)
      (state/state-advance-account-sequence
       (state/state-assoc-account
        (state/state-genesis)
        (value/put-symbol "address")
        (account/account-value-create (value/put-nil)) 0)
       (value/put-symbol "address") 0)
      0 (value/put-symbol "proposer") nil
      (transaction/transaction-put
       "otherexec" (value/put-symbol "address") 0
       (op/constant (value/put-integer "7")) nil 10
       (value/put-integer "1") nil))
     "transaction")])
  => '(true 1))
