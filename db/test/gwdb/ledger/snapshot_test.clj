(ns gwdb.ledger.snapshot-test
  (:use code.test)
  (:require [tahto.core :as l]
            [postgres.core :as pg]
            [gwdb.ledger.base :as base]
            [gwdb.ledger.snapshot :as snapshot]
            [gwdb.ledger.state :as state]))

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
             [gwdb.ledger.snapshot :as snapshot]
             [gwdb.ledger.state :as state]]
   :static {:application ["gw"]
            :seed ["gw_ledger"]
            :all {:schema ["gw_ledger"]}}})

(fact:global
 {:setup [(l/rt:teardown :postgres)
          (l/rt:setup :postgres)]
  :teardown [(l/rt:teardown :postgres)
             (l/rt:stop)]})

^{:refer gwdb.ledger.snapshot/snapshot-valid :added "0.1"}
(fact "snapshot creation commits generated state descriptor and HCP0 pack bytes"
  (!.pg
   [:select
    (snapshot/snapshot-valid
     (snapshot/snapshot-create (state/state-genesis) 0))]
   [:select
    (==
     (snapshot/snapshot-import
      (snapshot/snapshot-export
       (snapshot/snapshot-create (state/state-genesis) 0)))
     (snapshot/snapshot-create (state/state-genesis) 0))])
  => '(true true))

^{:refer gwdb.ledger.snapshot/snapshot-reachable-count :added "0.2"}
(fact "snapshot traversal follows CellRef edges and de-duplicates shared roots"
  (!.pg
   [:select
    (snapshot/snapshot-reachable-count (state/state-genesis))])
  => 3)

^{:refer gwdb.ledger.snapshot/snapshot-pack-import :added "0.2"}
(fact "HCP0 pack parsing restores cells before ordered CellRef envelopes"
  (!.pg
   [:select
    (snapshot/snapshot-pack-import
     (snapshot/snapshot-pack (state/state-genesis))
     (snapshot/snapshot-reachable-count (state/state-genesis)))])
  => true)


^{:refer gwdb.ledger.snapshot/Snapshot :added "0.1"}
(fact "TODO")

^{:refer gwdb.ledger.snapshot/snapshot-payload :added "0.1"}
(fact "TODO")

^{:refer gwdb.ledger.snapshot/snapshot-get :added "0.1"}
(fact "TODO")

^{:refer gwdb.ledger.snapshot/snapshot-root-seen-at :added "0.1"}
(fact "TODO")

^{:refer gwdb.ledger.snapshot/snapshot-root-tail :added "0.1"}
(fact "TODO")

^{:refer gwdb.ledger.snapshot/snapshot-reachable-roots-at :added "0.1"}
(fact "TODO")

^{:refer gwdb.ledger.snapshot/snapshot-reachable-roots :added "0.1"}
(fact "TODO")

^{:refer gwdb.ledger.snapshot/snapshot-pack-ref-tail :added "0.1"}
(fact "TODO")

^{:refer gwdb.ledger.snapshot/snapshot-pack-cells-at :added "0.1"}
(fact "TODO")

^{:refer gwdb.ledger.snapshot/snapshot-pack :added "0.1"}
(fact "TODO")

^{:refer gwdb.ledger.snapshot/snapshot-import-cells-at :added "0.1"}
(fact "TODO")

^{:refer gwdb.ledger.snapshot/snapshot-import-ref-tail :added "0.1"}
(fact "TODO")

^{:refer gwdb.ledger.snapshot/snapshot-import-refs-at :added "0.1"}
(fact "TODO")

^{:refer gwdb.ledger.snapshot/snapshot-put :added "0.1"}
(fact "TODO")

^{:refer gwdb.ledger.snapshot/snapshot-create :added "0.1"}
(fact "TODO")

^{:refer gwdb.ledger.snapshot/snapshot-export :added "0.1"}
(fact "TODO")

^{:refer gwdb.ledger.snapshot/snapshot-import :added "0.1"}
(fact "TODO")