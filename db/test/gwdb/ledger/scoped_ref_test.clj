(ns gwdb.ledger.scoped-ref-test
  (:use code.test)
  (:require [tahto.core :as l]
            [postgres.core :as pg]
            [gwdb.ledger.base :as base]
            [gwdb.ledger.scoped-ref :as scoped-ref]
            [gwdb.ledger.value :as value]))

(l/script- :postgres
  {:runtime :jdbc.client
   :config {:dbname "gw-ledger-test"
            :temp :create
            :container {:group "gw-ledger"
                        :image "gw-ledger-postgres:15-pgsodium"
                        :ports [5432]
                        :environment {"POSTGRES_PASSWORD" "postgres"
                                      "POSTGRES_USER" "postgres"
                                      "POSTGRES_HOST_AUTH_METHOD" "md5"
                                      "IGNATIUS_PGSODIUM_ROOT_KEY"
                                      "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"}
                        :cmd ["postgres" "-c" "password_encryption=md5"]}}
   :require [[postgres.core :as pg]
             [gwdb.ledger.base :as base :primary true]
             [gwdb.ledger.scoped-ref :as scoped-ref]
             [gwdb.ledger.value :as value]]
   :static {:application ["gw"]
            :seed ["gw_ledger"]
            :all {:schema ["gw_ledger"]}}})

(fact:global
 {:setup [(l/rt:teardown :postgres)
          (l/rt:setup :postgres)]
  :teardown [(l/rt:teardown :postgres)
             (l/rt:stop)]})

(defn.pg ^{:- [:jsonb]}
  run-scoped-ref-demo
  {:added "0.10"}
  []
  (let [(:bytea v-authority) (value/put-symbol "authority/alice")
        (:bytea v-authority-bob) (value/put-symbol "authority/bob")
        (:bytea v-commit-a) (value/put-string "commit-A")
        (:bytea v-commit-b) (value/put-string "commit-B")
        (:bytea v-commit-c) (value/put-string "commit-C")
        (:bytea v-user-a) (value/put-string "commit-user-A")
        (:bytea v-other-a) (value/put-string "other-commit-A")
        (:bytea v-unknown)
        (pg/decode
         "0000000000000000000000000000000000000000000000000000000000000000"
         "hex")
        _ (pg/t:delete scoped-ref/ScopedRef)
        (:jsonb o-capabilities) (scoped-ref/scoped-ref-capabilities)
        (:jsonb o-missing)
        (scoped-ref/scoped-ref-read
         "workspace/orbital-station" "main" v-authority)
        (:jsonb o-missing-auth)
        (scoped-ref/scoped-ref-read
         "workspace/orbital-station" "main" nil)
        (:jsonb o-invalid-scope)
        (scoped-ref/scoped-ref-read
         "Workspace With Spaces" "main" v-authority)
        (:jsonb o-unknown-desired)
        (scoped-ref/scoped-ref-compare-and-set
         "workspace/orbital-station" "unknown"
         nil v-unknown v-authority)
        (:jsonb o-create)
        (scoped-ref/scoped-ref-compare-and-set
         "workspace/orbital-station" "main"
         nil v-commit-a v-authority)
        (:jsonb o-read-a)
        (scoped-ref/scoped-ref-read
         "workspace/orbital-station" "main" v-authority)
        (:jsonb o-advance)
        (scoped-ref/scoped-ref-compare-and-set
         "workspace/orbital-station" "main"
         v-commit-a v-commit-b v-authority)
        (:jsonb o-stale)
        (scoped-ref/scoped-ref-compare-and-set
         "workspace/orbital-station" "main"
         v-commit-a v-commit-c v-authority-bob)
        (:jsonb o-user)
        (scoped-ref/scoped-ref-compare-and-set
         "workspace/orbital-station" "user/alice"
         nil v-user-a v-authority)
        (:jsonb o-other)
        (scoped-ref/scoped-ref-compare-and-set
         "workspace/other" "main"
         nil v-other-a v-authority)
        (:jsonb o-read-b)
        (scoped-ref/scoped-ref-read
         "workspace/orbital-station" "main" v-authority)
        o-main (scoped-ref/scoped-ref-row
                "workspace/orbital-station" "main")
        o-user-row (scoped-ref/scoped-ref-row
                    "workspace/orbital-station" "user/alice")
        o-other-row (scoped-ref/scoped-ref-row
                     "workspace/other" "main")
        (:bigint v-count) (pg/t:count scoped-ref/ScopedRef {})]
    (return
     (pg/jsonb-build-object
      "consistency" (:text (:->> o-capabilities "ref_consistency"))
      "missing_status" (:text (:->> o-missing "status"))
      "missing_root_is_null" [(:->> o-missing "root") :is-null]
      "missing_auth_error" (:text (:->> o-missing-auth "error"))
      "invalid_scope_error" (:text (:->> o-invalid-scope "error"))
      "unknown_desired_error" (:text (:->> o-unknown-desired "error"))
      "create_status" (:text (:->> o-create "status"))
      "create_version" (:bigint (:->> o-create "version"))
      "read_a_matches"
      (== (:text (:->> o-read-a "root"))
          (pg/encode v-commit-a "hex"))
      "advance_status" (:text (:->> o-advance "status"))
      "advance_version" (:bigint (:->> o-advance "version"))
      "stale_status" (:text (:->> o-stale "status"))
      "stale_error" (:text (:->> o-stale "error"))
      "stale_actual_matches"
      (== (:text (:->> o-stale "actual_root"))
          (pg/encode v-commit-b "hex"))
      "stale_preserved_main"
      (== (:bytea (:->> o-main "root")) v-commit-b)
      "last_authority_preserved"
      (== (:bytea (:->> o-main "authorization_root")) v-authority)
      "read_b_version" (:bigint (:->> o-read-b "version"))
      "user_independent"
      (== (:bytea (:->> o-user-row "root")) v-user-a)
      "scope_independent"
      (== (:bytea (:->> o-other-row "root")) v-other-a)
      "row_count" v-count
      "framed_lock_keys_differ"
      (not
       (== (scoped-ref/scoped-ref-lock-key "a" "bc")
           (scoped-ref/scoped-ref-lock-key "ab" "c")))))))

^{:refer gwdb.ledger.scoped-ref/scoped-ref-compare-and-set :added "0.10"}
(fact "PostgreSQL scoped refs provide exact-root linearizable compare-and-set"
  (!.pg
   [:select (:->> (-/run-scoped-ref-demo) "consistency")]
   [:select (:->> (-/run-scoped-ref-demo) "missing_status")]
   [:select (:->> (-/run-scoped-ref-demo) "missing_root_is_null")]
   [:select (:->> (-/run-scoped-ref-demo) "missing_auth_error")]
   [:select (:->> (-/run-scoped-ref-demo) "invalid_scope_error")]
   [:select (:->> (-/run-scoped-ref-demo) "unknown_desired_error")]
   [:select (:->> (-/run-scoped-ref-demo) "create_status")]
   [:select (:->> (-/run-scoped-ref-demo) "create_version")]
   [:select (:->> (-/run-scoped-ref-demo) "read_a_matches")]
   [:select (:->> (-/run-scoped-ref-demo) "advance_status")]
   [:select (:->> (-/run-scoped-ref-demo) "advance_version")]
   [:select (:->> (-/run-scoped-ref-demo) "stale_status")]
   [:select (:->> (-/run-scoped-ref-demo) "stale_error")]
   [:select (:->> (-/run-scoped-ref-demo) "stale_actual_matches")]
   [:select (:->> (-/run-scoped-ref-demo) "stale_preserved_main")]
   [:select (:->> (-/run-scoped-ref-demo) "last_authority_preserved")]
   [:select (:->> (-/run-scoped-ref-demo) "read_b_version")]
   [:select (:->> (-/run-scoped-ref-demo) "user_independent")]
   [:select (:->> (-/run-scoped-ref-demo) "scope_independent")]
   [:select (:->> (-/run-scoped-ref-demo) "row_count")]
   [:select (:->> (-/run-scoped-ref-demo) "framed_lock_keys_differ")])
  => '("linearizable" "ok" true
       "storage/missing-ref-authorization"
       "storage/invalid-ref-scope"
       "storage/unknown-desired-ref-root"
       "ok" 1 true "ok" 2
       "conflict" "storage/ref-conflict"
       true true true 2 true true 3 true))
