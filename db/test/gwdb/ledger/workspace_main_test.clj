(ns gwdb.ledger.workspace-main-test
  (:use code.test)
  (:require [tahto.core :as l]
            [postgres.core :as pg]
            [gwdb.ledger.base :as base]
            [gwdb.ledger.admission :as admission]
            [gwdb.ledger.developer :as developer]
            [gwdb.ledger.scoped-ref :as scoped-ref]
            [gwdb.ledger.value :as value]
            [gwdb.ledger.workspace :as workspace]
            [gwdb.ledger.workspace-proposal :as workspace-proposal]
            [gwdb.ledger.workspace-review :as workspace-review]
            [gwdb.ledger.workspace-acceptance :as workspace-acceptance]
            [gwdb.ledger.workspace-main :as workspace-main]))

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
             [gwdb.ledger.workspace-proposal :as workspace-proposal]
             [gwdb.ledger.workspace-review :as workspace-review]
             [gwdb.ledger.workspace-acceptance :as workspace-acceptance]
             [gwdb.ledger.workspace-main :as workspace-main]]
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

(def +alice-private-seed+
  "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")

(def +alice-public-key+
  "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")

(def +bob-private-seed+
  "4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb")

(def +bob-public-key+
  "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c")

(defn sign-payload
  [private-seed payload-hex]
  (let [spec
        (java.security.spec.EdECPrivateKeySpec.
         java.security.spec.NamedParameterSpec/ED25519
         (hex-bytes private-seed))
        factory (java.security.KeyFactory/getInstance "Ed25519")
        private-key (.generatePrivate factory spec)
        signer (java.security.Signature/getInstance "Ed25519")]
    (.initSign signer private-key)
    (.update signer (hex-bytes payload-hex))
    (bytes-hex (.sign signer))))

(defn register-account
  [network public-key private-seed timestamp]
  (let [request
        (admission/admission-registration-signing-request
         network public-key)
        signature
        (hex-bytes
         (sign-payload
          private-seed
          (json-field request "signing_payload")))]
    (admission/admission-register-account
     network public-key signature timestamp)))

(defn.pg ^{:- [:bytea]}
  author-evidence
  {:added "0.16"}
  [:bytea i-signer-root]
  (return
   (workspace-review/review-recorded-evidence-value
    i-signer-root 1)))

(defn.pg ^{:- [:bytea]}
  root-vector
  {:added "0.16"}
  [:jsonb i-roots]
  (return (value/put-vector i-roots)))

(defn.pg ^{:- [:jsonb]}
  main-fixture
  "Builds one genesis and one descendant candidate."
  {:added "0.16"}
  [:bytea i-authority-root]
  (let [(:bytea v-evidence) (-/author-evidence i-authority-root)
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
         nil nil v-evidence nil v-empty-map v-empty-map)]
    (return
     (pg/jsonb-build-object
      "workspace_id_root" (pg/encode v-workspace "hex")
      "c0" (pg/encode v-c0 "hex")
      "c1" (pg/encode v-c1 "hex")))))

(defn publish-proposal
  [network public-key private-seed workspace-id-root candidate-root
   timestamp]
  (let [request
        (workspace-proposal/workspace-proposal-signing-request
         network public-key workspace-id-root candidate-root 20)
        signature
        (hex-bytes
         (sign-payload
          private-seed
          (json-field request "signing_payload")))]
    (workspace-proposal/workspace-proposal-submit
     network public-key
     (long (json-field request "sequence"))
     workspace-id-root candidate-root 20 signature timestamp)))

(defn publish-review
  [network public-key private-seed workspace-id-root candidate-root
   timestamp]
  (let [request
        (workspace-review/workspace-review-signing-request
         network public-key workspace-id-root candidate-root
         nil "approve" timestamp 20)
        signature
        (hex-bytes
         (sign-payload
          private-seed
          (json-field request "signing_payload")))]
    (workspace-review/workspace-review-submit
     network public-key
     (long (json-field request "sequence"))
     workspace-id-root candidate-root nil
     "approve" timestamp 20 signature)))

^{:refer gwdb.ledger.workspace-main/workspace-main-submit :added "0.16"}
(fact "signed unanimous evidence bootstraps and advances workspace main"
  (let [network "workspace-main-acceptance"
        alice-public-key (hex-bytes +alice-public-key+)
        bob-public-key (hex-bytes +bob-public-key+)
        _ (developer/developer-genesis network 0)
        alice
        (register-account
         network alice-public-key +alice-private-seed+ 1)
        bob
        (register-account
         network bob-public-key +bob-private-seed+ 2)
        alice-address-hex (json-field alice "address")
        bob-address-hex (json-field bob "address")
        alice-address-root (hex-bytes alice-address-hex)
        bob-address-root (hex-bytes bob-address-hex)
        fixture (-/main-fixture alice-address-root)
        workspace-id-root
        (hex-bytes (json-field fixture "workspace_id_root"))
        c0 (hex-bytes (json-field fixture "c0"))
        c1 (hex-bytes (json-field fixture "c1"))
        reviewer-roots-root
        (-/root-vector
         (pg/jsonb-build-array
          alice-address-hex bob-address-hex))

        policy-request
        (workspace-acceptance/workspace-main-policy-signing-request
         network alice-public-key workspace-id-root
         reviewer-roots-root 3 20)
        policy-signature
        (hex-bytes
         (sign-payload
          +alice-private-seed+
          (json-field policy-request "signing_payload")))
        policy-result
        (workspace-acceptance/workspace-main-policy-submit
         network alice-public-key
         (long (json-field policy-request "sequence"))
         workspace-id-root reviewer-roots-root
         3 20 policy-signature)
        policy-root
        (hex-bytes (json-field policy-result "policy_root"))

        proposal-c0
        (publish-proposal
         network alice-public-key +alice-private-seed+
         workspace-id-root c0 4)
        alice-review-c0
        (publish-review
         network alice-public-key +alice-private-seed+
         workspace-id-root c0 5)
        bob-review-c0
        (publish-review
         network bob-public-key +bob-private-seed+
         workspace-id-root c0 6)
        alice-review-c0-root
        (hex-bytes (json-field alice-review-c0 "review_root"))
        bob-review-c0-root
        (hex-bytes (json-field bob-review-c0 "review_root"))
        c0-review-roots-root
        (-/root-vector
         (pg/jsonb-build-array
          (bytes-hex alice-review-c0-root)
          (bytes-hex bob-review-c0-root)))

        main-c0-request
        (workspace-main/workspace-main-signing-request
         network alice-public-key workspace-id-root nil c0
         policy-root c0-review-roots-root 7 20)
        main-c0-signature
        (hex-bytes
         (sign-payload
          +alice-private-seed+
          (json-field main-c0-request "signing_payload")))
        main-c0-result
        (workspace-main/workspace-main-submit
         network alice-public-key
         (long (json-field main-c0-request "sequence"))
         workspace-id-root nil c0 policy-root
         c0-review-roots-root 7 20 main-c0-signature)
        main-c0-acceptance-root
        (hex-bytes (json-field main-c0-result "acceptance_root"))

        proposal-c1
        (publish-proposal
         network alice-public-key +alice-private-seed+
         workspace-id-root c1 8)
        alice-review-c1
        (publish-review
         network alice-public-key +alice-private-seed+
         workspace-id-root c1 9)
        bob-review-c1
        (publish-review
         network bob-public-key +bob-private-seed+
         workspace-id-root c1 10)
        alice-review-c1-root
        (hex-bytes (json-field alice-review-c1 "review_root"))
        bob-review-c1-root
        (hex-bytes (json-field bob-review-c1 "review_root"))
        c1-review-roots-root
        (-/root-vector
         (pg/jsonb-build-array
          (bytes-hex alice-review-c1-root)
          (bytes-hex bob-review-c1-root)))

        main-c1-request
        (workspace-main/workspace-main-signing-request
         network alice-public-key workspace-id-root c0 c1
         policy-root c1-review-roots-root 11 20)
        main-c1-signature
        (hex-bytes
         (sign-payload
          +alice-private-seed+
          (json-field main-c1-request "signing_payload")))
        main-c1-result
        (workspace-main/workspace-main-submit
         network alice-public-key
         (long (json-field main-c1-request "sequence"))
         workspace-id-root c0 c1 policy-root
         c1-review-roots-root 11 20 main-c1-signature)
        main-c1-acceptance-root
        (hex-bytes (json-field main-c1-result "acceptance_root"))

        stale-request
        (workspace-main/workspace-main-signing-request
         network alice-public-key workspace-id-root c0 c1
         policy-root c1-review-roots-root 12 20)
        stale-signature
        (hex-bytes
         (sign-payload
          +alice-private-seed+
          (json-field stale-request "signing_payload")))
        stale-result
        (workspace-main/workspace-main-submit
         network alice-public-key
         (long (json-field stale-request "sequence"))
         workspace-id-root c0 c1 policy-root
         c1-review-roots-root 12 20 stale-signature)

        reversed-review-roots-root
        (-/root-vector
         (pg/jsonb-build-array
          (bytes-hex bob-review-c1-root)
          (bytes-hex alice-review-c1-root)))
        reversed-reviewers
        (try
          (workspace-main/workspace-main-signing-request
           network alice-public-key workspace-id-root c1 c1
           policy-root reversed-review-roots-root 13 20)
          (catch Throwable _ :rejected))
        replayed
        (try
          (workspace-main/workspace-main-submit
           network alice-public-key
           (long (json-field main-c1-request "sequence"))
           workspace-id-root c0 c1 policy-root
           c1-review-roots-root 11 20 main-c1-signature)
          (catch Throwable _ :rejected))

        scope (json-field main-c1-result "scope")
        main-row (scoped-ref/scoped-ref-row scope "main")
        policy-row (scoped-ref/scoped-ref-row scope "policy/main")
        main-read
        (scoped-ref/scoped-ref-read scope "main" policy-root)
        c0-acceptance-row
        (workspace-main/workspace-main-acceptance-row
         main-c0-acceptance-root)
        c1-acceptance-row
        (workspace-main/workspace-main-acceptance-row
         main-c1-acceptance-root)
        head (developer/developer-head network)]
    [(json-field policy-result "status")
     (json-field proposal-c0 "status")
     (json-field alice-review-c0 "status")
     (json-field bob-review-c0 "status")
     (json-field main-c0-result "status")
     (json-field main-c0-result "ref_version")
     (= (json-field main-c0-result "acceptance_root")
        (json-field main-c0-result "result_root"))
     (= (json-field main-c0-result "candidate_root")
        (bytes-hex c0))
     (json-field proposal-c1 "status")
     (json-field alice-review-c1 "status")
     (json-field bob-review-c1 "status")
     (json-field main-c1-result "status")
     (json-field main-c1-result "ref_version")
     (= (json-field main-c1-result "acceptance_root")
        (json-field main-c1-result "result_root"))
     (= (json-field main-read "root") (bytes-hex c1))
     (= (:bytea (json-field main-row "authorization_root")) policy-root)
     (= (:bytea (json-field policy-row "root")) policy-root)
     (workspace-main/workspace-main-acceptance-valid
      main-c0-acceptance-root)
     (workspace-main/workspace-main-acceptance-valid
      main-c1-acceptance-root)
     (= (:bytea (json-field c0-acceptance-row "candidate_root")) c0)
     (= (:bytea (json-field c1-acceptance-row "expected_root")) c0)
     (= (:bytea (json-field c1-acceptance-row "candidate_root")) c1)
     (= (:bytea (json-field c1-acceptance-row "policy_root")) policy-root)
     (= (:bytea (json-field c1-acceptance-row "review_roots_root"))
        c1-review-roots-root)
     (json-field stale-result "status")
     (json-field stale-result "error")
     (= (json-field stale-result "actual_root") (bytes-hex c1))
     (json-field stale-request "sequence")
     reversed-reviewers
     replayed
     (json-field head "height")
     (= alice-address-hex (json-field main-c1-result "address"))
     (= bob-address-hex (bytes-hex bob-address-root))])
  => ["ok" "ok" "ok" "ok"
      "ok" 1 true true
      "ok" "ok" "ok"
      "ok" 2 true true true true
      true true true true true true true
      "conflict" "storage/ref-conflict" true 7
      :rejected :rejected 11 true true])
