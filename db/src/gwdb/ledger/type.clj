(ns gwdb.ledger.type
  (:require [tahto.core :as l]
            [postgres.core :as pg]))

(l/script :postgres
  {:require [[postgres.core :as pg]]
   :config {:dbname "gw-ledger-test"}
   :import [["pgcrypto"]]
   :static {:application ["gw"]
            :seed ["gw_ledger"]
            :all {:schema ["gw_ledger"]}}})

;; These tags are protocol values, not PostgreSQL enum ordinals.  Keep the
;; numbers stable when the database schema evolves.
(def +type-tags+
  {:nil 0
   :boolean 1
   :integer 2
   :double 3
   :character 4
   :string 5
   :blob 6
   :symbol 7
   :keyword 8
   :list 9
   :vector 10
   :map 11
   :set 12
   :syntax 13
   :record 14
   :reference 15
   :primitive 16
   :operation 17
   :function 18
   :iterator-plan 19
   :iterator 20})

(def +codec-version+ 1)
(def +hash-size+ 32)
