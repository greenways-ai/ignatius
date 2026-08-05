(ns gwdb.ledger.integrity
  (:require [tahto.core :as l]
            [postgres.core :as pg]
            [gwdb.ledger.cell :as cell]
            [gwdb.ledger.codec :as codec]
            [gwdb.ledger.state :as state]
            [gwdb.ledger.account :as account]
            [gwdb.ledger.value :as value]
            [gwdb.ledger.module :as module]
            [gwdb.ledger.block :as block]))

(l/script :postgres
  {:require [[postgres.core :as pg]
             [gwdb.ledger.cell :as cell]
             [gwdb.ledger.codec :as codec]
             [gwdb.ledger.state :as state]
             [gwdb.ledger.account :as account]
             [gwdb.ledger.value :as value]
             [gwdb.ledger.module :as module]
             [gwdb.ledger.block :as block]]
   :config {:dbname "gw-ledger-test"}
   :import [["pgcrypto"]]
   :static {:application ["gw"]
            :all {:schema ["gw_ledger"]}}})

(defn.pg ^{:- [:boolean]}
  cell-integrity
  "Checks a content-addressed cell independently of every derived projection."
  {:added "0.2"}
  [:bytea i-root]
  (let [o-cell (cell/cell-by-hash i-root)]
    (return (and [o-cell :is-not-null]
                 (== (:integer (:->> o-cell "codec_version")) 1)
                 (codec/verify i-root
                               (:integer (:->> o-cell "type_tag"))
                               (:bytea (:->> o-cell "payload")))))))

(defn.pg ^{:- [:boolean]}
  state-integrity
  "Checks a state root and each of its fixed committed child cells."
  {:added "0.2"}
  [:bytea i-state-root]
  (return (and (-/cell-integrity i-state-root)
               (state/state-root-valid i-state-root)
               (-/cell-integrity (state/state-version-root i-state-root))
               (-/cell-integrity (state/state-accounts-root i-state-root))
               (-/cell-integrity (state/state-modules-root i-state-root))
               (-/cell-integrity (state/state-module-aliases-root i-state-root))
               (-/cell-integrity (state/state-validators-root i-state-root))
               (-/cell-integrity (state/state-settings-root i-state-root)))))

(defn.pg ^{:- [:boolean]}
  block-integrity
  "Checks a block payload, state roots, and the head-independent block graph."
  {:added "0.2"}
  [:bytea i-block-root]
  (let [o-block (block/block-get i-block-root)]
    (return (and [o-block :is-not-null]
                 (-/cell-integrity i-block-root)
                 (block/block-valid i-block-root)
                 (-/state-integrity
                  (:bytea (:->> o-block "previous_state_root")))
                 (-/state-integrity
                  (:bytea (:->> o-block "state_root")))))))

(defn.pg ^{:- [:boolean]}
  head-integrity
  "Verifies that a mutable head only points at a valid matching block/state."
  {:added "0.2"}
  [:text i-network]
  (let [o-head (block/head-get i-network)
        o-block (block/block-get (:bytea (:->> o-head "block_root")))]
    (return (and [o-head :is-not-null]
                 [o-block :is-not-null]
                 (-/block-integrity (:bytea (:->> o-head "block_root")))
                 (== (:bigint (:->> o-head "height"))
                     (:bigint (:->> o-block "height")))
                 (== (:bytea (:->> o-head "state_root"))
                     (:bytea (:->> o-block "state_root")))))))

(defn.pg rebuild-account-projection
  "Rebuilds one Account projection row exclusively from an immutable state map."
  {:added "0.2"}
  [:bytea i-state-root :bytea i-address-root]
  (let [(:bytea v-account-root) (state/state-account-root i-state-root i-address-root)
        _ (pg/assert [v-account-root :is-not-null] [:ledger/missing-account])
        (:bigint v-sequence)
        (value/integer-bigint
         (account/account-value-sequence-root v-account-root))
        o-row (account/account-put
               i-address-root v-sequence i-state-root
               (account/account-value-environment-root v-account-root)
               (account/account-value-metadata-root v-account-root)
               (account/account-value-controller-root v-account-root))]
    (return o-row)))

(defn.pg ^{:- [:boolean]}
  rebuild-module-export-projection-at
  "Rebuilds one canonical module export-set position at a time."
  {:added "0.2"}
  [:bytea i-module-root :bytea i-exports-root :integer i-position :integer i-count]
  (cond (>= i-position i-count) (return true)
        :else
        (let [(:bytea v-symbol-root)
              (cell/cell-ref-child i-exports-root i-position "element")
              (:bytea v-value-root) (module/module-export i-module-root v-symbol-root)
              o-projection (module/module-export-put
                            i-module-root v-symbol-root v-value-root)]
          (return (-/rebuild-module-export-projection-at
                   i-module-root i-exports-root (+ i-position 1) i-count)))))

(defn.pg ^{:- [:boolean]}
  rebuild-module-export-projection
  "Rebuilds ModuleExport rows from immutable module environment/export roots."
  {:added "0.2"}
  [:bytea i-module-root]
  (let [o-module (module/module-get i-module-root)
        _ (pg/assert [o-module :is-not-null] [:ledger/missing-module])
        (:bytea v-exports-root) (:bytea (:->> o-module "exports_root"))
        (:integer v-count) (cell/cell-ref-count v-exports-root "element")]
    (return (-/rebuild-module-export-projection-at
             i-module-root v-exports-root 0 v-count))))
