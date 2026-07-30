(ns gwdb.ledger.cell
  (:require [tahto.core :as l]
            [postgres.core :as pg]
            [gwdb.ledger.type :as type]
            [gwdb.ledger.codec :as codec]))

(l/script :postgres
  {:require [[postgres.core :as pg]
             [gwdb.ledger.type :as type]
             [gwdb.ledger.codec :as codec]]
   :config {:dbname "gw-ledger-test"}
   :import [["pgcrypto"]]
   :static {:application ["gw"]
            :all {:schema ["gw_ledger"]}}})

(deftype.pg Cell
  "Immutable content-addressed Hara value cell."
  {:added "0.1"}
  [:hash          {:type :bytea :primary true}
   :codec-version {:type :smallint :required true}
   :type-tag      {:type :smallint :required true}
   :payload       {:type :bytea :required true}
   :byte-size     {:type :integer :required true}
   :created-at    {:type :time :required true
                   :sql {:default (pg/time-us)}}])

(deftype.pg CellRef
  "Derived child references for traversing committed cell payloads."
  {:added "0.1"}
  [:parent-hash {:type :bytea :required true :primary true}
   :position    {:type :integer :required true :primary true}
   :role        {:type :text :required true :primary true}
   :child-hash  {:type :bytea :required true}]
  {})

(defn.pg ^{:- [:trigger]}
  cell-immutable
  "Rejects every direct mutation of an authoritative content-addressed cell."
  {:added "0.1"}
  []
  (pg/assert false [:ledger/immutable-cell])
  (return OLD))

(deftrigger.pg ^{:- [:before :update]}
  cell-immutable-update-trigger
  [gwdb.ledger.cell/Cell]
  [:for-each-row
   :execute-function (-/cell-immutable)])

(deftrigger.pg ^{:- [:before :delete]}
  cell-immutable-delete-trigger
  [gwdb.ledger.cell/Cell]
  [:for-each-row
   :execute-function (-/cell-immutable)])

(defn.pg ^{:- [:boolean]
           :%% :sql
           :props [:immutable :parallel-safe]}
  cell-hash-valid
  "Validates a cell hash without consulting mutable database state."
  {:added "0.1"}
  [:bytea i-hash]
  (codec/hash-valid i-hash))

(defn.pg ^{:- [:boolean]
           :%% :sql
           :props [:immutable :parallel-safe]}
  cell-valid
  "Verifies the complete immutable cell envelope before insertion or export."
  {:added "0.1"}
  [:bytea i-hash
   :integer i-codec-version
   :integer i-type-tag
   :bytea i-payload]
  (and (== i-codec-version 1)
       (codec/verify i-hash i-type-tag i-payload)))

(defn.pg
  cell-by-hash
  {:added "0.1"}
  [:bytea i-hash]
  (let [o-cell (pg/t:get -/Cell
                          {:where {:hash i-hash}})]
    (return o-cell)))

(defn.pg ^{:- [:integer]}
  cell-type-tag
  "Returns the stable protocol type tag for an existing cell."
  {:added "0.1"}
  [:bytea i-hash]
  (let [o-cell (-/cell-by-hash i-hash)
        _ (pg/assert [o-cell :is-not-null]
                     [:ledger/missing-cell])
        (:integer v-type-tag) (:->> o-cell "type_tag")]
    (return v-type-tag)))

(defn.pg ^{:- [:integer]}
  cell-ref-count
  "Counts derived references of one role for an immutable parent cell."
  {:added "0.1"}
  [:bytea i-parent-hash :text i-role]
  (let [(:integer o-count) (pg/t:count -/CellRef
                                        {:where {:parent-hash i-parent-hash
                                                 :role i-role}})]
    (return o-count)))

(defn.pg ^{:- [:bytea]}
  cell-ref-child
  "Returns one child committed by a canonical cell reference role and position."
  {:added "0.1"}
  [:bytea i-parent-hash :integer i-position :text i-role]
  (let [o-row (pg/t:get -/CellRef
                        {:where {:parent-hash i-parent-hash
                                 :position i-position
                                 :role i-role}})
        _ (pg/assert [o-row :is-not-null]
                     [:ledger/missing-cell-reference])
        (:bytea v-child) (:->> o-row "child_hash")]
    (return v-child)))

(defn.pg ^{:- [:jsonb]}
  cell-ref-children
  "Returns all committed child references in a stable role/position order."
  {:added "0.2"}
  [:bytea i-parent-hash]
  (let [(:jsonb v-rows)
        (pg/t:select -/CellRef
                     {:where {:parent-hash i-parent-hash}
                      :returning #{:child-hash}
                      :order-by [:role :position]})]
    (return (pg/coalesce v-rows (pg/jsonb-build-array)))))

(defn.pg ^{:- [:jsonb]}
  cell-ref-entries
  "Returns complete child-reference envelopes in stable role/position order."
  {:added "0.2"}
  [:bytea i-parent-hash]
  (let [(:jsonb v-rows)
        (pg/t:select -/CellRef
                     {:where {:parent-hash i-parent-hash}
                      :returning #{:position :role :child-hash}
                      :order-by [:role :position]})]
    (return (pg/coalesce v-rows (pg/jsonb-build-array)))))

(defn.pg ^{:- [:bytea]}
  cell-put
  "Inserts a validated cell once and returns its immutable root."
  {:added "0.1"}
  [:bytea i-hash
   :integer i-codec-version
   :integer i-type-tag
   :bytea i-payload]
  (let [(:integer v-size) (pg/length i-payload)
        o-existing (-/cell-by-hash i-hash)
        (:jsonb o-insert) nil
        _ (pg/assert (== i-codec-version 1)
                     [:ledger/unsupported-codec i-codec-version])
        _ (pg/assert (codec/valid-type-tag i-type-tag)
                     [:ledger/unknown-type-tag i-type-tag])
        _ (pg/assert (== (pg/length i-hash) 32)
                     [:ledger/invalid-hash-length])
        _ (pg/assert (-/cell-valid i-hash i-codec-version i-type-tag i-payload)
                     [:ledger/hash-mismatch])]
    (cond [o-existing :is-not-null]
          (do (pg/assert (== (:smallint (:->> o-existing "codec_version"))
                             i-codec-version)
                         [:ledger/cell-codec-conflict])
              (pg/assert (== (:smallint (:->> o-existing "type_tag"))
                             i-type-tag)
                         [:ledger/cell-type-conflict])
              (pg/assert (== (:bytea (:->> o-existing "payload")) i-payload)
                         [:ledger/cell-payload-conflict])
              (return i-hash))
          :else
          (do (pg/t:insert -/Cell
                            {:hash i-hash
                             :codec-version i-codec-version
                             :type-tag i-type-tag
                             :payload i-payload
                             :byte-size v-size}
                            {:into o-insert})
              (return i-hash)))))

(defn.pg cell-ref-put
  "Records one derived ordered child reference after both cells exist."
  {:added "0.1"}
  [:bytea i-parent-hash
   :integer i-position
   :text i-role
   :bytea i-child-hash]
  (let [_ (pg/assert (-/cell-hash-valid i-parent-hash)
                     [:ledger/invalid-parent-hash])
        _ (pg/assert (-/cell-hash-valid i-child-hash)
                     [:ledger/invalid-child-hash])
        _ (pg/assert (>= i-position 0)
                     [:ledger/invalid-reference-position])
        _ (pg/assert [(-/cell-by-hash i-parent-hash) :is-not-null]
                     [:ledger/missing-parent-cell])
        _ (pg/assert [(-/cell-by-hash i-child-hash) :is-not-null]
                     [:ledger/missing-child-cell])
        o-row (pg/t:upsert -/CellRef
                           {:parent-hash i-parent-hash
                            :position i-position
                            :role i-role
                            :child-hash i-child-hash}
                           {:on-conflict #{:parent-hash :position :role}})]
    (return o-row)))

(defn.pg ^{:- [:boolean]} cell-ref-valid
  "Checks that a derived reference points to existing immutable cells."
  {:added "0.1"}
  [:bytea i-parent-hash :bytea i-child-hash]
  (return (and [(-/cell-by-hash i-parent-hash) :is-not-null]
               [(-/cell-by-hash i-child-hash) :is-not-null])))
