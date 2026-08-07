(ns gwdb.ledger.workspace-admission-test
  (:use code.test)
  (:require [tahto.core :as l]
            [postgres.core :as pg]
            [gwdb.ledger.base :as base]
            [gwdb.ledger.admission :as admission]
            [gwdb.ledger.developer :as developer]
            [gwdb.ledger.scoped-ref :as scoped-ref]
            [gwdb.ledger.value :as value]
            [gwdb.ledger.workspace :as workspace]
            [gwdb.ledger.workspace-admission :as workspace-admission]))

(l/script- :postgres
  {:runtime :jdbc.client
   :config {:dbname "gw-ledger-test"
            :temp :create
            :vendor :impossibl
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
             [gwdb.ledger.admission :as admission]
             [gwdb.ledger.developer :as developer]
             [gwdb.ledger.scoped-ref :as scoped-ref]
             [gwdb.ledger.value :as value]
             [gwdb.ledger.workspace :as workspace]
             [gwdb.ledger.workspace-admission :as workspace-admission]]
   :static {:application ["gw"]
            :seed ["gw_ledger"]
            :all {:schema ["gw_ledger"]}}})

(fact:global
 {:setup [(l/rt:teardown :postgres)
          (l/rt:setup :postgres)]
  :teardown [(l/rt:teardown :postgres)
             (l/rt:stop)]})

(defn hex-bytes
  [text]
  (.parseHex (java.util.HexFormat/of) text))

(defn bytes-hex
  [bytes]
  (.formatHex (java.util.HexFormat/of) bytes))

(defn json-field
  [value field]
  (or (get value field)
      (get value (keyword field))))

(def +private-seed+
  "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")

(def +public-key+
  "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")

(defn sign-payload
  [payload-hex]
  (let [spec
        (java.security.spec.EdECPrivateKeySpec.
         java.security.spec.NamedParameterSpec/ED25519
         (hex-bytes +private-seed+))
        factory (java.security.KeyFactory/getInstance "Ed25519")
        private-key (.generatePrivate factory spec)
        signer (java.security.Signature/getInstance "Ed25519")]
    (.initSign signer private-key)
    (.update signer (hex-bytes payload-hex))
    (bytes-hex (.sign signer))))

(defn.pg ^{:- [:bytea]}
  author-evidence
  {:added "0.12"}
  [:bytea i-signer-root]
  (let [(:bytea v-record)
        (workspace/record-start "ledger/evidence")
        (:bytea v-version)
        (workspace/record-assoc
         v-record "record/version" (value/put-integer-number 1))
        (:bytea v-extensions)
        (workspace/record-assoc
         v-version "record/extensions"
         (value/put-map (pg/jsonb-build-array)))
        (:bytea v-signer)
        (workspace/record-assoc
         v-extensions "ledger/signer" i-signer-root)
        (:bytea v-transaction)
        (workspace/record-assoc
         v-signer "ledger/transaction-root" (value/put-nil))
        (:bytea v-timestamp)
        (workspace/record-assoc
         v-transaction "ledger/timestamp"
         (value/put-integer-number 1700000000))
        (:bytea v-head)
        (workspace/record-assoc
         v-timestamp "ledger/previous-head-root" (value/put-nil))
        (:bytea v-contract)
        (workspace/record-assoc
         v-head "ledger/contract-root" (value/put-nil))
        (:bytea v-template)
        (workspace/record-assoc
         v-contract "ledger/template-root" (value/put-nil))]
    (return
     (workspace/record-assoc
      v-template "ledger/global-state-root" (value/put-nil)))))

(defn.pg ^{:- [:bytea]}
  root-vector
  {:added "0.12"}
  [:jsonb i-roots]
  (return (value/put-vector i-roots)))

(defn.pg ^{:- [:jsonb]}
  workspace-fixture
  "Builds two sibling branches and one later descendant idempotently."
  {:added "0.12"}
  [:bytea i-public-key]
  (let [(:bytea v-address)
        (admission/admission-address-root i-public-key)
        (:bytea v-evidence) (-/author-evidence v-address)
        (:bytea v-workspace)
        (value/put-string "world/orbital-station")
        (:bytea v-empty-map)
        (value/put-map (pg/jsonb-build-array))
        (:bytea v-c0)
        (workspace/workspace-commit-put
         v-workspace nil
         (-/root-vector (pg/jsonb-build-array))
         (value/put-string "W0")
         nil nil nil v-evidence nil v-empty-map v-empty-map)
        (:bytea v-c1)
        (workspace/workspace-commit-put
         v-workspace nil
         (-/root-vector
          (pg/jsonb-build-array (pg/encode v-c0 "hex")))
         (value/put-string "W1")
         (value/put-string "edit-1")
         nil nil v-evidence nil v-empty-map v-empty-map)
        (:bytea v-c2)
        (workspace/workspace-commit-put
         v-workspace nil
         (-/root-vector
          (pg/jsonb-build-array (pg/encode v-c0 "hex")))
         (value/put-string "W2")
         (value/put-string "edit-2")
         nil nil v-evidence nil v-empty-map v-empty-map)
        (:bytea v-c3)
        (workspace/workspace-commit-put
         v-workspace nil
         (-/root-vector
          (pg/jsonb-build-array (pg/encode v-c1 "hex")))
         (value/put-string "W3")
         (value/put-string "edit-3")
         nil nil v-evidence nil v-empty-map v-empty-map)]
    (return
     (pg/jsonb-build-object
      "workspace_id_root" (pg/encode v-workspace "hex")
      "c0" (pg/encode v-c0 "hex")
      "c1" (pg/encode v-c1 "hex")
      "c2" (pg/encode v-c2 "hex")
      "c3" (pg/encode v-c3 "hex")))))

^{:refer gwdb.ledger.workspace-admission/workspace-ref-submit :added "0.12"}
(fact "signed personal branch updates commit only successful exact-root selections"
  (let [network "workspace-signed"
        public-key (hex-bytes +public-key+)
        _ (developer/developer-genesis network 0)
        registration-request
        (admission/admission-registration-signing-request
         network public-key)
        registration-signature
        (hex-bytes
         (sign-payload
          (json-field registration-request "signing_payload")))
        registration
        (admission/admission-register-account
         network public-key registration-signature 1)
        address-hex (json-field registration "address")
        fixture (-/workspace-fixture public-key)
        workspace-id-root
        (hex-bytes (json-field fixture "workspace_id_root"))
        c0 (hex-bytes (json-field fixture "c0"))
        c1 (hex-bytes (json-field fixture "c1"))
        c2 (hex-bytes (json-field fixture "c2"))
        c3 (hex-bytes (json-field fixture "c3"))

        create-request
        (workspace-admission/workspace-ref-signing-request
         network public-key workspace-id-root nil c0 20)
        create-signature
        (hex-bytes
         (sign-payload
          (json-field create-request "signing_payload")))
        create-result
        (workspace-admission/workspace-ref-submit
         network public-key
         (long (json-field create-request "sequence"))
         workspace-id-root nil c0 20 create-signature 2)

        advance-request
        (workspace-admission/workspace-ref-signing-request
         network public-key workspace-id-root c0 c1 20)
        advance-signature
        (hex-bytes
         (sign-payload
          (json-field advance-request "signing_payload")))
        advance-result
        (workspace-admission/workspace-ref-submit
         network public-key
         (long (json-field advance-request "sequence"))
         workspace-id-root c0 c1 20 advance-signature 3)

        stale-request
        (workspace-admission/workspace-ref-signing-request
         network public-key workspace-id-root c0 c2 20)
        stale-signature
        (hex-bytes
         (sign-payload
          (json-field stale-request "signing_payload")))
        stale-result
        (workspace-admission/workspace-ref-submit
         network public-key
         (long (json-field stale-request "sequence"))
         workspace-id-root c0 c2 20 stale-signature 4)

        after-conflict-request
        (workspace-admission/workspace-ref-signing-request
         network public-key workspace-id-root c1 c3 20)
        later-signature
        (hex-bytes
         (sign-payload
          (json-field after-conflict-request "signing_payload")))
        later-result
        (workspace-admission/workspace-ref-submit
         network public-key
         (long (json-field after-conflict-request "sequence"))
         workspace-id-root c1 c3 20 later-signature 5)

        replayed
        (try
          (workspace-admission/workspace-ref-submit
           network public-key
           (long (json-field after-conflict-request "sequence"))
           workspace-id-root c1 c3 20 later-signature 6)
          (catch Throwable _ :rejected))
        non-fast-forward
        (try
          (workspace-admission/workspace-ref-signing-request
           network public-key workspace-id-root c1 c2 20)
          (catch Throwable _ :rejected))
        scope (json-field later-result "scope")
        name (json-field later-result "name")
        personal-read
        (scoped-ref/scoped-ref-read
         scope name (hex-bytes address-hex))
        main-row (scoped-ref/scoped-ref-row scope "main")
        head (developer/developer-head network)]
    [(json-field create-result "status")
     (json-field create-result "ref_version")
     (json-field advance-result "status")
     (json-field advance-result "ref_version")
     (json-field stale-result "status")
     (json-field stale-result "error")
     (= (json-field stale-result "actual_root")
        (bytes-hex c1))
     (json-field after-conflict-request "sequence")
     (json-field later-result "status")
     (json-field later-result "ref_version")
     (= (json-field later-result "intent_root")
        (json-field later-result "result_root"))
     scope
     (= name (str "user/" address-hex))
     (= (json-field personal-read "root")
        (bytes-hex c3))
     (nil? main-row)
     (workspace/workspace-commit-valid c2)
     (json-field head "height")
     replayed
     non-fast-forward
     (= address-hex (json-field later-result "address"))])
  => ["ok" 1
      "ok" 2
      "conflict" "storage/ref-conflict" true
      2
      "ok" 3 true
      "workspace/world/orbital-station" true
      true true true 4 :rejected :rejected true])
