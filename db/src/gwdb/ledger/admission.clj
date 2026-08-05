(ns gwdb.ledger.admission
  (:require [tahto.core :as l]
            [postgres.core :as pg]
            [gwdb.ledger.account :as account]
            [gwdb.ledger.block :as block]
            [gwdb.ledger.crypto :as crypto]
            [gwdb.ledger.document :as document]
            [gwdb.ledger.op :as op]
            [gwdb.ledger.state :as state]
            [gwdb.ledger.transaction :as transaction]
            [gwdb.ledger.value :as value]))

;; This namespace is the public signed-admission boundary.  It intentionally
;; has no key-generation or private-key handling: browsers own the Ed25519
;; private key and PostgreSQL sees only a public key and detached signatures.
(l/script :postgres
  {:require [[postgres.core :as pg]
             [gwdb.ledger.account :as account]
             [gwdb.ledger.block :as block]
             [gwdb.ledger.crypto :as crypto]
             [gwdb.ledger.document :as document]
             [gwdb.ledger.op :as op]
             [gwdb.ledger.state :as state]
             [gwdb.ledger.transaction :as transaction]
             [gwdb.ledger.value :as value]]
   :config {:dbname "gw-ledger-test"}
   :import [["pgcrypto"] ["pgsodium"]]
   :static {:application ["gw"]
            :all {:schema ["gw_ledger"]}}})

(defn.pg ^{:- [:bytea] :%% :sql :props [:immutable :parallel-safe]}
  admission-registration-payload
  "The exact domain-separated bytes a new controller signs to prove possession
   before its account is created."
  {:added "0.4"}
  [:text i-network :bytea i-public-key]
  (pg/decode
   (|| "R:account-registration:1:" i-network ":" (pg/encode i-public-key "hex"))
   "escape"))

(defn.pg ^{:- [:bytea] :%% :sql :props [:immutable :parallel-safe]}
  admission-document-create-payload
  {:added "0.5"}
  [:text i-document-id :bytea i-owner-key :bytea i-syntax-root]
  (pg/decode (|| "R:document-create:1:" i-document-id ":"
                  (pg/encode i-owner-key "hex") ":" (pg/encode i-syntax-root "hex"))
             "escape"))

(defn.pg ^{:- [:bytea] :%% :sql :props [:immutable :parallel-safe]}
  admission-document-edit-payload
  {:added "0.5"}
  [:text i-document-id :bytea i-base-revision :bytea i-operation-root :bytea i-owner-key]
  (pg/decode (|| "R:document-edit:1:" i-document-id ":"
                  (pg/encode i-base-revision "hex") ":" (pg/encode i-operation-root "hex") ":"
                  (pg/encode i-owner-key "hex"))
             "escape"))

(defn.pg ^{:- [:jsonb]}
  admission-document-text-create-signing-request
  {:added "0.5"}
  [:text i-document-id :bytea i-owner-key :text i-text]
  (let [(:bytea v-syntax) (document/document-text-syntax i-document-id i-text)
        (:bytea v-payload) (-/admission-document-create-payload i-document-id i-owner-key v-syntax)]
    (return (pg/jsonb-build-object "syntax_root" (pg/encode v-syntax "hex")
                                   "signing_payload" (pg/encode v-payload "hex")))))

(defn.pg ^{:- [:jsonb]}
  admission-document-text-replace-signing-request
  {:added "0.5"}
  [:text i-document-id :bytea i-base-revision :bytea i-owner-key :text i-node-id :text i-text]
  (let [(:bytea v-syntax) (document/document-text-syntax i-node-id i-text)
        (:bytea v-operation) (document/document-operation-put "replace" i-node-id nil nil v-syntax)
        (:bytea v-payload) (-/admission-document-edit-payload i-document-id i-base-revision v-operation i-owner-key)]
    (return (pg/jsonb-build-object "operation_root" (pg/encode v-operation "hex")
                                   "signing_payload" (pg/encode v-payload "hex")))))

(defn.pg ^{:- [:jsonb]}
  admission-document-create-signing-request
  {:added "0.5"}
  [:text i-document-id :bytea i-owner-key :bytea i-syntax-root]
  (let [(:bytea v-payload) (-/admission-document-create-payload i-document-id i-owner-key i-syntax-root)]
    (return (pg/jsonb-build-object "signing_payload" (pg/encode v-payload "hex")))))

(defn.pg ^{:- [:jsonb]}
  admission-document-edit-signing-request
  {:added "0.5"}
  [:text i-document-id :bytea i-base-revision :bytea i-owner-key :bytea i-operation-root]
  (let [(:bytea v-payload) (-/admission-document-edit-payload i-document-id i-base-revision i-operation-root i-owner-key)]
    (return (pg/jsonb-build-object "signing_payload" (pg/encode v-payload "hex")))))

(defn.pg ^{:- [:jsonb]}
  admission-document-create
  {:added "0.5"}
  [:text i-document-id :bytea i-owner-key :bytea i-syntax-root :bytea i-signature]
  (let [(:bytea v-payload) (-/admission-document-create-payload i-document-id i-owner-key i-syntax-root)
        _ (pg/assert (crypto/signature-verify i-signature v-payload i-owner-key)
                     [:ledger/invalid-document-create-signature])
        (:bytea v-revision) (document/document-create i-document-id i-owner-key i-syntax-root)]
    (return (pg/jsonb-build-object "revision_root" (pg/encode v-revision "hex")
                                   "document" (document/document-head i-document-id)))))

(defn.pg ^{:- [:jsonb]}
  admission-document-edit
  {:added "0.5"}
  [:text i-document-id :bytea i-base-revision :bytea i-owner-key :bytea i-operation-root :bytea i-signature]
  (let [(:bytea v-payload) (-/admission-document-edit-payload i-document-id i-base-revision i-operation-root i-owner-key)
        _ (pg/assert (crypto/signature-verify i-signature v-payload i-owner-key)
                     [:ledger/invalid-document-edit-signature])
        (:bytea v-revision) (document/document-apply-operation i-document-id i-base-revision i-owner-key i-operation-root)]
    (return (pg/jsonb-build-object "revision_root" (pg/encode v-revision "hex")
                                   "document" (document/document-head i-document-id)))))

(defn.pg ^{:- [:bytea]}
  admission-address-root
  "Derives an account address value from a controller key, never from a
   mutable display name."
  {:added "0.4"}
  [:bytea i-public-key]
  (let [_ (pg/assert (crypto/public-key-valid i-public-key)
                     [:ledger/invalid-controller-key])]
    (return (value/put-blob (crypto/account-address-payload i-public-key)))))

(defn.pg ^{:- [:bytea]}
  admission-controller-root
  {:added "0.4"}
  [:bytea i-public-key]
  (let [_ (pg/assert (crypto/public-key-valid i-public-key)
                     [:ledger/invalid-controller-key])]
    (return (value/put-blob i-public-key))))

(defn.pg ^{:- [:bytea]}
  admission-proposer-root
  {:added "0.4"}
  []
  (return (value/put-symbol "gwdb.ledger.admission")))

(defn.pg ^{:- [:jsonb]}
  admission-registration-signing-request
  "Returns the canonical account-registration bytes that the browser must
   sign.  Keeping this in the database prevents client/server framing drift."
  {:added "0.4"}
  [:text i-network :bytea i-public-key]
  (let [_ (pg/assert (crypto/public-key-valid i-public-key)
                     [:ledger/invalid-controller-key])
        (:bytea v-payload)
        (-/admission-registration-payload i-network i-public-key)]
    (return (pg/jsonb-build-object
             "public_key" (pg/encode i-public-key "hex")
             "signing_payload" (pg/encode v-payload "hex")))))

(defn.pg ^{:- [:jsonb]}
  admission-register-account
  "Creates a controller-bound account after the browser proves possession of
   its Ed25519 private key.  Registration itself is committed as an empty
   block transition; subsequent state changes require signed transactions."
  {:added "0.4"}
  [:text i-network :bytea i-public-key :bytea i-signature :bigint i-timestamp]
  (let [_ (pg/assert (crypto/signature-verify
                      i-signature
                      (-/admission-registration-payload i-network i-public-key)
                      i-public-key)
                     [:ledger/invalid-account-registration-signature])
        o-head (block/head-lock i-network)
        _ (pg/assert [o-head :is-not-null] [:ledger/network-missing])
        (:bytea v-previous-state) (:bytea (:->> o-head "state_root"))
        (:bigint v-previous-height) (:bigint (:->> o-head "height"))
        (:bytea v-address-root) (-/admission-address-root i-public-key)
        (:bytea v-existing) (state/state-account-root v-previous-state v-address-root)
        _ (pg/assert [v-existing :is-null] [:ledger/account-exists])
        (:bytea v-controller-root) (-/admission-controller-root i-public-key)
        (:bytea v-account-root) (account/account-value-create v-controller-root)
        (:bytea v-state-root)
        (state/state-assoc-account v-previous-state v-address-root v-account-root
                                   (+ v-previous-height 1))
        (:bytea v-block-root)
        (block/block-commit i-network v-previous-height v-previous-state
                            (+ v-previous-height 1)
                            (:bytea (:->> o-head "block_root")) v-previous-state
                            v-state-root i-timestamp (-/admission-proposer-root) nil
                            (pg/jsonb-build-array))]
    (return (pg/jsonb-build-object
             "address" (pg/encode v-address-root "hex")
             "public_key" (pg/encode i-public-key "hex")
             "state_root" (pg/encode v-state-root "hex")
             "block_root" (pg/encode v-block-root "hex")))))

(defn.pg ^{:- [:jsonb]}
  admission-integer-signing-request
  "Builds the exact bytes to sign for the restricted public integer example.
   It returns no private material and does not accept a transaction yet."
  {:added "0.4"}
  [:text i-network :bytea i-public-key :text i-integer :bigint i-cost-limit]
  (let [o-head (block/head-get i-network)
        _ (pg/assert [o-head :is-not-null] [:ledger/network-missing])
        (:bytea v-state-root) (:bytea (:->> o-head "state_root"))
        (:bytea v-address-root) (-/admission-address-root i-public-key)
        (:bytea v-account-root) (state/state-account-root v-state-root v-address-root)
        _ (pg/assert [v-account-root :is-not-null] [:ledger/missing-account])
        (:bytea v-controller-root) (account/account-value-controller-root v-account-root)
        (:bytea v-expected-controller) (-/admission-controller-root i-public-key)
        _ (pg/assert (== v-controller-root v-expected-controller)
                     [:ledger/controller-mismatch])
        (:bigint v-sequence)
        (value/integer-bigint (account/account-value-sequence-root v-account-root))
        (:bytea v-op-root) (op/constant (value/put-integer i-integer))
        (:bytea v-runtime-root) (value/put-integer "1")
        (:bytea v-payload)
        (transaction/transaction-signing-payload
         i-network v-address-root v-sequence v-op-root nil i-cost-limit v-runtime-root)]
    (return (pg/jsonb-build-object
             "address" (pg/encode v-address-root "hex")
             "sequence" v-sequence
             "signing_payload" (pg/encode v-payload "hex")))))

(defn.pg ^{:- [:jsonb]}
  admission-submit-integer
  "Accepts one browser-signed integer operation and commits its receipt and
   block atomically.  A stale signing request fails rather than being applied
   to a later account sequence."
  {:added "0.4"}
  [:text i-network :bytea i-public-key :bigint i-sequence :text i-integer
   :bigint i-cost-limit :bytea i-signature :bigint i-timestamp]
  (let [o-head (block/head-lock i-network)
        _ (pg/assert [o-head :is-not-null] [:ledger/network-missing])
        (:bytea v-previous-state) (:bytea (:->> o-head "state_root"))
        (:bigint v-previous-height) (:bigint (:->> o-head "height"))
        (:bytea v-address-root) (-/admission-address-root i-public-key)
        (:bytea v-account-root) (state/state-account-root v-previous-state v-address-root)
        _ (pg/assert [v-account-root :is-not-null] [:ledger/missing-account])
        (:bytea v-controller-root) (account/account-value-controller-root v-account-root)
        (:bytea v-expected-controller) (-/admission-controller-root i-public-key)
        _ (pg/assert (== v-controller-root v-expected-controller)
                     [:ledger/controller-mismatch])
        (:bigint v-current-sequence)
        (value/integer-bigint (account/account-value-sequence-root v-account-root))
        _ (pg/assert (== v-current-sequence i-sequence) [:ledger/sequence-conflict])
        (:bytea v-op-root) (op/constant (value/put-integer i-integer))
        (:bytea v-runtime-root) (value/put-integer "1")
        (:bytea v-transaction-root)
        (transaction/transaction-put
         i-network v-address-root i-sequence v-op-root nil i-cost-limit
         v-runtime-root i-signature)
        (:bytea v-receipt-root)
        (block/block-execute-signed-transaction
         v-transaction-root i-network v-previous-state
         (+ v-previous-height 1) i-timestamp)
        o-receipt (transaction/transaction-receipt-get v-receipt-root)
        (:bytea v-state-root) (:bytea (:->> o-receipt "state_root"))
        (:bytea v-block-root)
        (block/block-commit i-network v-previous-height v-previous-state
                            (+ v-previous-height 1)
                            (:bytea (:->> o-head "block_root")) v-previous-state
                            v-state-root i-timestamp (-/admission-proposer-root) nil
                            (pg/jsonb-build-array (pg/encode v-transaction-root "hex")))
        o-bound (block/block-transaction-bind v-block-root 0 v-receipt-root)]
    (return (pg/jsonb-build-object
             "address" (pg/encode v-address-root "hex")
             "transaction_root" (pg/encode v-transaction-root "hex")
             "receipt_root" (pg/encode v-receipt-root "hex")
             "state_root" (pg/encode v-state-root "hex")
             "block_root" (pg/encode v-block-root "hex")
             "status" (:text (:->> o-receipt "status"))))))

(defn.pg ^{:- [:jsonb]}
  admission-submit-operation
  "Accepts an already canonical, projection-validated operation graph.

   This is the general public transaction boundary used by offline compilers.
   The caller imports the authoritative cells and rebuilds each operation
   projection in the same SQL transaction before invoking this function."
  {:added "0.6"}
  [:text i-network :bytea i-public-key :bigint i-sequence :bytea i-op-root
   :bytea i-form-root :bigint i-cost-limit :bytea i-runtime-root
   :bytea i-signature :bigint i-timestamp]
  (let [o-head (block/head-lock i-network)
        _ (pg/assert [o-head :is-not-null] [:ledger/network-missing])
        (:bytea v-previous-state) (:bytea (:->> o-head "state_root"))
        (:bigint v-previous-height) (:bigint (:->> o-head "height"))
        (:bytea v-address-root) (-/admission-address-root i-public-key)
        (:bytea v-account-root) (state/state-account-root v-previous-state v-address-root)
        _ (pg/assert [v-account-root :is-not-null] [:ledger/missing-account])
        (:bytea v-controller-root) (account/account-value-controller-root v-account-root)
        (:bytea v-expected-controller) (-/admission-controller-root i-public-key)
        _ (pg/assert (== v-controller-root v-expected-controller)
                     [:ledger/controller-mismatch])
        (:bigint v-current-sequence)
        (value/integer-bigint (account/account-value-sequence-root v-account-root))
        _ (pg/assert (== v-current-sequence i-sequence) [:ledger/sequence-conflict])
        _ (pg/assert (op/op-valid i-op-root) [:ledger/invalid-op])
        (:bytea v-transaction-root)
        (transaction/transaction-put
         i-network v-address-root i-sequence i-op-root i-form-root i-cost-limit
         i-runtime-root i-signature)
        (:bytea v-receipt-root)
        (block/block-execute-signed-transaction
         v-transaction-root i-network v-previous-state
         (+ v-previous-height 1) i-timestamp)
        o-receipt (transaction/transaction-receipt-get v-receipt-root)
        (:bytea v-state-root) (:bytea (:->> o-receipt "state_root"))
        (:bytea v-block-root)
        (block/block-commit i-network v-previous-height v-previous-state
                            (+ v-previous-height 1)
                            (:bytea (:->> o-head "block_root")) v-previous-state
                            v-state-root i-timestamp (-/admission-proposer-root) nil
                            (pg/jsonb-build-array (pg/encode v-transaction-root "hex")))
        o-bound (block/block-transaction-bind v-block-root 0 v-receipt-root)]
    (return (pg/jsonb-build-object
             "address" (pg/encode v-address-root "hex")
             "transaction_root" (pg/encode v-transaction-root "hex")
             "receipt_root" (pg/encode v-receipt-root "hex")
             "result_root" (pg/encode (:bytea (:->> o-receipt "result_root")) "hex")
             "cost_used" (:bigint (:->> o-receipt "cost_used"))
             "state_root" (pg/encode v-state-root "hex")
             "block_root" (pg/encode v-block-root "hex")
             "status" (:text (:->> o-receipt "status"))))))
