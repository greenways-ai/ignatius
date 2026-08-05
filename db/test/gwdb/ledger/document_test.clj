(ns gwdb.ledger.document-test
  (:use code.test)
  (:require [tahto.core :as l]
            [postgres.core :as pg]
            [gwdb.ledger.base :as base]
            [gwdb.ledger.document :as document]
            [gwdb.ledger.ot :as ot]
            [gwdb.ledger.syntax :as syntax]
            [gwdb.ledger.value :as value]))

(l/script- :postgres
  {:runtime :jdbc.client
   :config {:dbname "gw-ledger-test" :temp :create :vendor :impossibl
            :container {:group "gw-ledger" :image "gw-ledger-postgres:15-pgsodium"
                        :ports [5432]
                        :environment {"POSTGRES_PASSWORD" "postgres" "POSTGRES_USER" "postgres"}
                        :cmd ["postgres"]}}
   :require [[postgres.core :as pg] [gwdb.ledger.base :as base :primary true]
             [gwdb.ledger.document :as document] [gwdb.ledger.ot :as ot]
             [gwdb.ledger.syntax :as syntax] [gwdb.ledger.value :as value]]
   :static {:application ["gw"] :seed ["gw_ledger"] :all {:schema ["gw_ledger"]}}})

(fact:global {:setup [(l/rt:teardown :postgres) (l/rt:setup :postgres)]
              :teardown [(l/rt:teardown :postgres) (l/rt:stop)]})

(defn.pg ^{:- [:bigint]}
  document-stale-delete-fixture
  []
  (let [(:bytea v-node-key) (value/put-keyword "node/id")
        (:bytea v-child-id) (value/put-string "018f0000-0000-7000-8000-000000000002")
        (:bytea v-child-meta)
        (value/put-map (pg/jsonb-build-array
                        (pg/encode v-node-key "hex")
                        (pg/encode v-child-id "hex")))
        (:bytea v-child)
        (syntax/put-syntax (value/put-integer "1") v-child-meta)
        (:bytea v-root-id) (value/put-string "018f0000-0000-7000-8000-000000000001")
        (:bytea v-root-meta)
        (value/put-map (pg/jsonb-build-array
                        (pg/encode v-node-key "hex")
                        (pg/encode v-root-id "hex")))
        (:bytea v-root)
        (syntax/put-syntax
         (value/put-vector (pg/jsonb-build-array (pg/encode v-child "hex")))
         v-root-meta)
        (:bytea v-owner)
        (pg/decode "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a" "hex")
        (:bytea v-base)
        (document/document-create "018f0000-0000-7000-8000-000000000010" v-owner v-root)
        (:bytea v-operation)
        (document/document-operation-put
         "delete" "018f0000-0000-7000-8000-000000000002" nil nil nil)
        (:bytea v-first)
        (document/document-apply-operation
         "018f0000-0000-7000-8000-000000000010" v-base v-owner v-operation)
        (:bytea v-stale)
        (document/document-apply-operation
         "018f0000-0000-7000-8000-000000000010" v-base v-owner v-operation)
        (:jsonb v-head)
        (document/document-head "018f0000-0000-7000-8000-000000000010")]
    (return (:bigint (pg/jsonb-extract-path-text v-head "next_order")))))

(fact "syntax-node edits preserve immutable history and turn a deleted stale target into a noop"
  (!.pg [:select (-/document-stale-delete-fixture)])
  => 3)
