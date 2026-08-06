(ns gwdb.ledger.account-runtime
  (:require [tahto.core :as l]
            [postgres.core :as pg]
            [gwdb.ledger.account :as account]
            [gwdb.ledger.cell :as cell]
            [gwdb.ledger.context :as context]
            [gwdb.ledger.runtime :as runtime]
            [gwdb.ledger.runtime-support :as support]
            [gwdb.ledger.state :as state]
            [gwdb.ledger.value :as value]))

(l/script :postgres
  {:require [[postgres.core :as pg]
             [gwdb.ledger.account :as account]
             [gwdb.ledger.cell :as cell]
             [gwdb.ledger.context :as context]
             [gwdb.ledger.runtime :as runtime]
             [gwdb.ledger.runtime-support :as support]
             [gwdb.ledger.state :as state]
             [gwdb.ledger.value :as value]]
   :config {:dbname "gw-ledger-test"}
   :static {:application ["gw"]
            :all {:schema ["gw_ledger"]}}})

(defn.pg ^{:- [:boolean]}
  account-primitive-id
  {:added "0.8"}
  [:text i-primitive-id]
  (return
   (or (== i-primitive-id "account/exists")
       (== i-primitive-id "account/root")
       (== i-primitive-id "account/sequence")
       (== i-primitive-id "account/key")
       (== i-primitive-id "account/controller")
       (== i-primitive-id "account/environment")
       (== i-primitive-id "account/metadata")
       (== i-primitive-id "account/set-key")
       (== i-primitive-id "account/set-controller")
       (== i-primitive-id "account/set-definition-metadata"))))

(defn.pg ^{:- [:bytea]}
  account-root-at
  {:added "0.8"}
  [:bytea i-context-root :bytea i-address-root]
  (let [o-context (context/context-get i-context-root)]
    (return
     (state/state-account-root
      (:bytea (:->> o-context "state_root")) i-address-root))))

(defn.pg ^{:- [:jsonb]}
  read-account-field
  {:added "0.8"}
  [:bytea i-context-root :text i-primitive-id :jsonb i-roots]
  (let [(:bytea v-address-root) (support/root-at i-roots 0)
        (:bytea v-account-root)
        (-/account-root-at i-context-root v-address-root)
        (:bytea v-result-root)
        (pg/case [v-account-root :is-null]
                 (value/put-nil)
                 (== i-primitive-id "account/root")
                 v-account-root
                 (== i-primitive-id "account/sequence")
                 (account/account-value-sequence-root v-account-root)
                 (== i-primitive-id "account/key")
                 (account/account-value-key-root v-account-root)
                 (== i-primitive-id "account/controller")
                 (account/account-value-authority-root v-account-root)
                 (== i-primitive-id "account/environment")
                 (account/account-value-environment-root v-account-root)
                 :else
                 (account/account-value-metadata-root v-account-root))]
    (return
     (runtime/result-ok
      (context/context-charge i-context-root 1) v-result-root))))

(defn.pg ^{:- [:jsonb]}
  apply-account-exists
  {:added "0.8"}
  [:bytea i-context-root :jsonb i-roots]
  (let [(:bytea v-account-root)
        (-/account-root-at
         i-context-root (support/root-at i-roots 0))]
    (return
     (runtime/result-ok
      (context/context-charge i-context-root 1)
      (value/put-boolean
       (pg/case [v-account-root :is-null] false
                :else true))))))

(defn.pg ^{:- [:bytea]}
  replace-current-account
  "Replaces the active account in state and returns a charged successor context."
  {:added "0.8"}
  [:bytea i-context-root :bytea i-account-root :bigint i-cost]
  (let [o-context (context/context-get i-context-root)
        (:bytea v-state-root)
        (state/state-assoc-account
         (:bytea (:->> o-context "state_root"))
         (:bytea (:->> o-context "address"))
         i-account-root
         (:bigint (:->> o-context "block_height")))]
    (return
     (context/context-charge
      (context/context-with-state i-context-root v-state-root)
      i-cost))))

(defn.pg ^{:- [:jsonb]}
  apply-account-set-key
  {:added "0.8"}
  [:bytea i-context-root :jsonb i-roots]
  (let [o-context (context/context-get i-context-root)
        (:bytea v-account-root)
        (state/state-account-root
         (:bytea (:->> o-context "state_root"))
         (:bytea (:->> o-context "address")))
        _ (when [v-account-root :is-null]
            (return (runtime/result-error i-context-root "missing-account")))
        (:bytea v-key-root) (support/root-at i-roots 0)
        _ (when [(cell/cell-by-hash v-key-root) :is-null]
            (return (runtime/result-error i-context-root "missing-key-value")))
        (:bytea v-next-account)
        (account/account-value-set-key v-account-root v-key-root)
        (:bytea v-next-context)
        (-/replace-current-account i-context-root v-next-account 3)]
    (return (runtime/result-ok v-next-context v-key-root))))

(defn.pg ^{:- [:jsonb]}
  apply-account-set-controller
  {:added "0.8"}
  [:bytea i-context-root :jsonb i-roots]
  (let [o-context (context/context-get i-context-root)
        (:bytea v-account-root)
        (state/state-account-root
         (:bytea (:->> o-context "state_root"))
         (:bytea (:->> o-context "address")))
        _ (when [v-account-root :is-null]
            (return (runtime/result-error i-context-root "missing-account")))
        (:bytea v-controller-root) (support/root-at i-roots 0)
        _ (when [(cell/cell-by-hash v-controller-root) :is-null]
            (return (runtime/result-error
                     i-context-root "missing-controller-value")))
        (:bytea v-next-account)
        (account/account-value-set-controller
         v-account-root v-controller-root)
        (:bytea v-next-context)
        (-/replace-current-account i-context-root v-next-account 3)]
    (return (runtime/result-ok v-next-context v-controller-root))))

(defn.pg ^{:- [:jsonb]}
  apply-account-set-definition-metadata
  {:added "0.8"}
  [:bytea i-context-root :jsonb i-roots]
  (let [o-context (context/context-get i-context-root)
        (:bytea v-account-root)
        (state/state-account-root
         (:bytea (:->> o-context "state_root"))
         (:bytea (:->> o-context "address")))
        _ (when [v-account-root :is-null]
            (return (runtime/result-error i-context-root "missing-account")))
        (:bytea v-symbol-root) (support/root-at i-roots 0)
        (:bytea v-metadata-root) (support/root-at i-roots 1)
        _ (when (not (== (cell/cell-type-tag v-symbol-root) 7))
            (return (runtime/result-error
                     i-context-root "definition-symbol-required")))
        _ (when (not (== (cell/cell-type-tag v-metadata-root) 11))
            (return (runtime/result-error
                     i-context-root "definition-metadata-required")))
        (:bytea v-next-account)
        (account/account-value-set-definition-metadata
         v-account-root v-symbol-root v-metadata-root)
        (:bytea v-next-context)
        (-/replace-current-account i-context-root v-next-account 2)]
    (return (runtime/result-ok v-next-context v-metadata-root))))

(defn.pg ^{:- [:jsonb]}
  apply-primitive
  "Applies account and controller primitives to evaluated canonical roots."
  {:added "0.8"}
  [:bytea i-context-root :text i-primitive-id :jsonb i-roots]
  (let [(:bigint v-cost)
        (pg/case (or (== i-primitive-id "account/set-key")
                     (== i-primitive-id "account/set-controller"))
                 3
                 (== i-primitive-id "account/set-definition-metadata")
                 2
                 :else 1)
        _ (when (not (context/context-can-charge i-context-root v-cost))
            (return (runtime/result-error i-context-root "cost-limit")))]
    (cond (== i-primitive-id "account/exists")
          (return (-/apply-account-exists i-context-root i-roots))

          (or (== i-primitive-id "account/root")
              (== i-primitive-id "account/sequence")
              (== i-primitive-id "account/key")
              (== i-primitive-id "account/controller")
              (== i-primitive-id "account/environment")
              (== i-primitive-id "account/metadata"))
          (return
           (-/read-account-field
            i-context-root i-primitive-id i-roots))

          (== i-primitive-id "account/set-key")
          (return (-/apply-account-set-key i-context-root i-roots))

          (== i-primitive-id "account/set-controller")
          (return (-/apply-account-set-controller i-context-root i-roots))

          (== i-primitive-id "account/set-definition-metadata")
          (return
           (-/apply-account-set-definition-metadata
            i-context-root i-roots))

          :else
          (return
           (runtime/result-error i-context-root "unknown-account-primitive")))))