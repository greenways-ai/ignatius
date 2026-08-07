(ns gwdb.ledger.workspace-proposal-test
  (:use code.test)
  (:require [tahto.core :as l]
            [postgres.core :as pg]
            [gwdb.ledger.base :as base]
            [gwdb.ledger.admission :as admission]
            [gwdb.ledger.developer :as developer]
            [gwdb.ledger.scoped-ref :as scoped-ref]
            [gwdb.ledger.value :as value]
            [gwdb.ledger.workspace :as workspace]
            [gwdb.ledger.workspace-admission :as workspace-admission]
            [gwdb.ledger.workspace-proposal :as proposal]))

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
             [gwdb.ledger.workspace-admission :as workspace-admission]
             [gwdb.ledger.workspace-proposal :as proposal]]
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
  {:added "0.13"}
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
  {:added "0.13"}
  [:jsonb i-roots]
  (return (value/put-vector i-roots)))

(defn.pg ^{:- [:jsonb]}
  proposal-fixture
  "Builds two sibling candidates for independent review."
  {:added "0.13"}
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
         nil nil v-evidence nil v-empty-map v-empty-map)]
    (return
     (pg/jsonb-build-object
      "workspace_id_root" (pg/encode v-workspace "hex")
      "c0" (pg/encode v-c0 "hex")
      "c1" (pg/encode v-c1 "hex")
      "c2" (pg/encode v-c2 "hex")))))

^{:refer gwdb.ledger.workspace-proposal/workspace-proposal-submit :added "0.13"}
(fact "signed proposal publication is deterministic, create-only and linear"
  (let [network "workspace-proposals"
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
        address-root (hex-bytes address-hex)
        fixture (-/proposal-fixture public-key)
        workspace-id-root
        (hex-bytes (json-field fixture "workspace_id_root"))
        c1 (hex-bytes (json-field fixture "c1"))
        c2 (hex-bytes (json-field fixture "c2"))

        first-request
        (proposal/workspace-proposal-signing-request
         network public-key workspace-id-root c1 20)
        first-signature
        (hex-bytes
         (sign-payload
          (json-field first-request "signing_payload")))
        first-result
        (proposal/workspace-proposal-submit
         network public-key
         (long (json-field first-request "sequence"))
         workspace-id-root c1 20 first-signature 2)

        duplicate-request
        (proposal/workspace-proposal-signing-request
         network public-key workspace-id-root c1 20)
        duplicate-signature
        (hex-bytes
         (sign-payload
          (json-field duplicate-request "signing_payload")))
        duplicate-result
        (proposal/workspace-proposal-submit
         network public-key
         (long (json-field duplicate-request "sequence"))
         workspace-id-root c1 20 duplicate-signature 3)

        second-request
        (proposal/workspace-proposal-signing-request
         network public-key workspace-id-root c2 20)
        second-signature
        (hex-bytes
         (sign-payload
          (json-field second-request "signing_payload")))
        second-result
        (proposal/workspace-proposal-submit
         network public-key
         (long (json-field second-request "sequence"))
         workspace-id-root c2 20 second-signature 4)

        scope (json-field second-result "scope")
        first-name (json-field first-result "name")
        second-name (json-field second-result "name")
        first-read
        (scoped-ref/scoped-ref-read scope first-name address-root)
        second-read
        (scoped-ref/scoped-ref-read scope second-name address-root)
        main-row (scoped-ref/scoped-ref-row scope "main")
        personal-row
        (scoped-ref/scoped-ref-row
         scope (workspace-admission/personal-name address-root))
        release-row
        (scoped-ref/scoped-ref-row scope "release/1.0.0")
        head (developer/developer-head network)]
    [(json-field first-result "status")
     (json-field first-result "ref_version")
     (= (json-field first-result "intent_root")
        (json-field first-result "result_root"))
     (= first-name (str "proposal/" (bytes-hex c1)))
     (json-field duplicate-result "status")
     (json-field duplicate-result "error")
     (= (json-field duplicate-result "actual_root")
        (bytes-hex c1))
     (json-field second-request "sequence")
     (json-field second-result "status")
     (json-field second-result "ref_version")
     (= (json-field second-result "intent_root")
        (json-field second-result "result_root"))
     (= second-name (str "proposal/" (bytes-hex c2)))
     (= (json-field first-read "root") (bytes-hex c1))
     (= (json-field second-read "root") (bytes-hex c2))
     (nil? main-row)
     (nil? personal-row)
     (nil? release-row)
     (workspace/workspace-commit-valid c1)
     (workspace/workspace-commit-valid c2)
     (json-field head "height")
     (= address-hex (json-field second-result "address"))])
  => ["ok" 1 true true
      "conflict" "storage/ref-conflict" true
      1
      "ok" 1 true true true true
      true true true true true 3 true])
