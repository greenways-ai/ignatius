(ns gwdb.ledger.document-protocol
  (:require [tahto.core :as l]
            [postgres.core :as pg]
            [gwdb.ledger.codec :as codec]))

(l/script :postgres
  {:require [[postgres.core :as pg]
             [gwdb.ledger.codec :as codec]]
   :config {:dbname "gw-ledger-test"}
   :import [["pgcrypto"]]
   :static {:application ["gw"]
            :all {:schema ["gw_ledger"]}}})

(deftype.pg DocumentPolicy
  "Append-only policy versions governing one environment document."
  {:added "0.7"}
  [:policy-root {:type :bytea :primary true}
   :document-id {:type :text :required true}
   :previous-policy-root {:type :bytea}
   :profile-id {:type :text :required true}
   :environment-id {:type :text :required true}
   :policy {:type :jsonb :required true}
   :created-at {:type :time :required true :sql {:default (pg/time-us)}}])

(deftype.pg DocumentDelegation
  "Projection of a signed, purpose-scoped document key delegation."
  {:added "0.7"}
  [:delegation-root {:type :bytea :primary true}
   :identity-id {:type :text :required true}
   :subject-key {:type :bytea :required true}
   :document-id {:type :text}
   :environment-id {:type :text}
   :purposes {:type :jsonb :required true}
   :valid-from {:type :long :required true}
   :valid-through {:type :long :required true}
   :revoked-at {:type :long}])

(deftype.pg PersonalDocumentLog
  "A complete imported disclosure log, distinct from private working history."
  {:added "0.7"}
  [:log-id {:type :text :primary true}
   :document-id {:type :text :required true}
   :contributor-id {:type :text :required true}
   :head-root {:type :bytea}
   :next-sequence {:type :long :required true}
   :imported-at {:type :time :required true :sql {:default (pg/time-us)}}])

(deftype.pg DocumentChangeBatch
  "One signed storage envelope containing ordered, replayable operation roots."
  {:added "0.7"}
  [:batch-root {:type :bytea :primary true}
   :log-id {:type :text :required true}
   :sequence {:type :long :required true}
   :previous-entry-root {:type :bytea}
   :base-revision-root {:type :bytea :required true}
   :base-ast-root {:type :bytea :required true}
   :expected-result-root {:type :bytea :required true}
   :profile-root {:type :bytea :required true}
   :author-key {:type :bytea :required true}
   :delegation-root {:type :bytea :required true}
   :operation-roots {:type :jsonb :required true}
   :signature {:type :bytea :required true}])

(deftype.pg DocumentBatchOperation
  "Per-operation replay boundary and environment transformation outcome."
  {:added "0.7"}
  [:batch-root {:type :bytea :primary true}
   :position {:type :integer :primary true}
   :original-root {:type :bytea :required true}
   :transformed-root {:type :bytea}
   :result-root {:type :bytea}
   :status {:type :text :required true}
   :conflict {:type :text}])

(deftype.pg DocumentImportReceipt
  "Environment-signed disposition for an imported disclosure batch."
  {:added "0.7"}
  [:receipt-id {:type :text :primary true}
   :receipt-root {:type :bytea :required true}
   :document-id {:type :text :required true}
   :environment-id {:type :text :required true}
   :contributor-id {:type :text :required true}
   :log-id {:type :text :required true}
   :batch-root {:type :bytea :required true}
   :environment-sequence {:type :long :required true}
   :status {:type :text :required true}
   :accepted-revision-root {:type :bytea}
   :result-ast-root {:type :bytea}
   :submission-commitment {:type :bytea :required true}
   :result-commitment {:type :bytea}
   :environment-key {:type :bytea :required true}
   :signature {:type :bytea :required true}
   :created-at {:type :time :required true :sql {:default (pg/time-us)}}])

(deftype.pg DocumentApproval
  "Exact-root approval, rejection or withdrawal under a committed policy."
  {:added "0.7"}
  [:approval-root {:type :bytea :primary true}
   :document-id {:type :text :required true}
   :stage-id {:type :text :required true}
   :policy-root {:type :bytea :required true}
   :revision-root {:type :bytea :required true}
   :ast-root {:type :bytea :required true}
   :identity-id {:type :text :required true}
   :role {:type :text :required true}
   :decision {:type :text :required true}
   :delegation-root {:type :bytea :required true}
   :signature {:type :bytea :required true}])

(deftype.pg DocumentDelivery
  "Delivery proof over exact approvals, disposition coverage and artifacts."
  {:added "0.7"}
  [:delivery-root {:type :bytea :primary true}
   :document-id {:type :text :required true}
   :policy-root {:type :bytea :required true}
   :revision-root {:type :bytea :required true}
   :ast-root {:type :bytea :required true}
   :cutoff-sequence {:type :long :required true}
   :coverage-root {:type :bytea :required true}
   :exporter-root {:type :bytea :required true}
   :artifacts {:type :jsonb :required true}
   :disclosure-mode {:type :text :required true}
   :deliverer-key {:type :bytea :required true}
   :signature {:type :bytea :required true}
   :created-at {:type :time :required true :sql {:default (pg/time-us)}}])

(defn.pg ^{:- [:boolean] :%% :sql :props [:immutable :parallel-safe]}
  document-purpose-valid
  {:added "0.7"}
  [:text i-purpose]
  (or (== i-purpose "document.edit")
      (== i-purpose "document.approve")
      (== i-purpose "document.deliver")
      (== i-purpose "hestia.personal.append")
      (== i-purpose "hestia.environment.import")))

(defn.pg ^{:- [:boolean] :%% :sql :props [:immutable :parallel-safe]}
  document-batch-count-valid
  {:added "0.7"}
  [:integer i-count]
  (and (>= i-count 1) (<= i-count 64)))

(defn.pg ^{:- [:boolean] :%% :sql :props [:immutable :parallel-safe]}
  document-terminal-disposition
  {:added "0.7"}
  [:text i-status]
  (or (== i-status "accepted")
      (== i-status "resolved")
      (== i-status "rejected")
      (== i-status "abandoned")))

(defn.pg ^{:- [:bytea] :%% :sql :props [:immutable :parallel-safe]}
  document-protocol-signing-payload
  "GWDP1 NUL type NUL root; JSON projections never participate in signing."
  {:added "0.7"}
  [:text i-record-type :bytea i-body-root]
  (|| (pg/decode "475744503100" "hex")
      (convert-to i-record-type "UTF8")
      (pg/decode "00" "hex")
      i-body-root))

(defn.pg ^{:- [:bytea] :%% :sql :props [:immutable :parallel-safe]}
  document-blinded-commitment
  "Prevents public receipts from exposing guessable raw content roots."
  {:added "0.7"}
  [:bytea i-root :bytea i-salt]
  (codec/sha256
   (|| (pg/decode "47574450313a626c696e643a" "hex")
       i-salt i-root)))
