(ns gwdb.ledger.account
  (:require [tahto.core :as l]
            [postgres.core :as pg]
            [gwdb.ledger.cell :as cell]
            [gwdb.ledger.codec :as codec]
            [gwdb.ledger.value :as value]))

(l/script :postgres
  {:require [[postgres.core :as pg]
             [gwdb.ledger.cell :as cell]
             [gwdb.ledger.codec :as codec]
             [gwdb.ledger.value :as value]]
   :config {:dbname "gw-ledger-test"}
   :import [["pgcrypto"]]
   :static {:application ["gw"]
            :all {:schema ["gw_ledger"]}}})

(deftype.pg Account
  "Rebuildable account projection keyed by an immutable state root."
  {:added "0.1"}
  [:address       {:type :bytea :primary true}
   :sequence      {:type :long :required true}
   :state-root    {:type :bytea :required true}
   :environment-root {:type :bytea :required true}
   :metadata-root {:type :bytea :required true}
   :controller    {:type :bytea}
   :created-at    {:type :time :required true
                   :sql {:default (pg/time-us)}}])

(deftype.pg Definition
  "Rebuildable symbol lookup projection for an account environment."
  {:added "0.1"}
  [:address    {:type :bytea :primary true}
   :symbol-root {:type :bytea :primary true}
   :value-root {:type :bytea :required true}
   :state-root {:type :bytea :required true}
   :created-at {:type :time :required true
                :sql {:default (pg/time-us)}}])

(defn.pg ^{:- [:bytea]} account-value-payload
  "Builds the fixed HCV1 account-record payload from four committed roots."
  {:added "0.1"}
  [:bytea i-sequence-root
   :bytea i-environment-root
   :bytea i-metadata-root
   :bytea i-controller-root]
  (return
   (pg/decode
    (|| "R:account:1:4:"
        (pg/encode i-sequence-root "hex")
        (pg/encode i-environment-root "hex")
        (pg/encode i-metadata-root "hex")
        (pg/encode i-controller-root "hex"))
    "escape")))

(defn.pg ^{:- [:bytea]} account-value-put
  "Commits an immutable semantic account record and its child references."
  {:added "0.1"}
  [:bytea i-sequence-root
   :bytea i-environment-root
   :bytea i-metadata-root
   :bytea i-controller-root]
  (let [o-sequence (cell/cell-by-hash i-sequence-root)
        o-environment (cell/cell-by-hash i-environment-root)
        o-metadata (cell/cell-by-hash i-metadata-root)
        o-controller (cell/cell-by-hash i-controller-root)
        _ (pg/assert (and [o-sequence :is-not-null]
                          (== (:smallint (:->> o-sequence "type_tag")) 2))
                     [:ledger/account-sequence-not-integer])
        _ (pg/assert (and [o-environment :is-not-null]
                          (== (:smallint (:->> o-environment "type_tag")) 11))
                     [:ledger/account-environment-not-map])
        _ (pg/assert (and [o-metadata :is-not-null]
                          (== (:smallint (:->> o-metadata "type_tag")) 11))
                     [:ledger/account-metadata-not-map])
        _ (pg/assert [o-controller :is-not-null]
                     [:ledger/missing-account-controller])
        (:bytea v-payload) (-/account-value-payload
                            i-sequence-root i-environment-root
                            i-metadata-root i-controller-root)
        (:bytea v-root) (cell/cell-put (codec/canonical-hash 14 v-payload)
                                       1 14 v-payload)
        o-sequence-ref (cell/cell-ref-put v-root 0 "sequence" i-sequence-root)
        o-environment-ref (cell/cell-ref-put v-root 1 "environment" i-environment-root)
        o-metadata-ref (cell/cell-ref-put v-root 2 "metadata" i-metadata-root)
        o-controller-ref (cell/cell-ref-put v-root 3 "controller" i-controller-root)]
    (return v-root)))

(defn.pg ^{:- [:bytea]} account-value-create
  "Creates the canonical account value used inside a state accounts map."
  {:added "0.1"}
  [:bytea i-controller-root]
  (let [(:bytea v-sequence) (value/put-integer "0")
        (:bytea v-environment) (value/put-map (pg/jsonb-build-array))
        (:bytea v-metadata) (value/put-map (pg/jsonb-build-array))]
    (return (-/account-value-put v-sequence v-environment v-metadata
                                 i-controller-root))))

(defn.pg ^{:- [:bytea]} account-value-sequence-root
  {:added "0.1"}
  [:bytea i-account-root]
  (return (cell/cell-ref-child i-account-root 0 "sequence")))

(defn.pg ^{:- [:bytea]} account-value-environment-root
  {:added "0.1"}
  [:bytea i-account-root]
  (return (cell/cell-ref-child i-account-root 1 "environment")))

(defn.pg ^{:- [:bytea]} account-value-metadata-root
  {:added "0.1"}
  [:bytea i-account-root]
  (return (cell/cell-ref-child i-account-root 2 "metadata")))

(defn.pg ^{:- [:bytea]} account-value-controller-root
  {:added "0.1"}
  [:bytea i-account-root]
  (return (cell/cell-ref-child i-account-root 3 "controller")))

(defn.pg ^{:- [:bytea]} account-value-define-empty
  "Creates a new account value by associating one symbol/value definition.

   The historical name is retained for the first account transition API; the
   implementation now works for an empty or populated canonical environment."
  {:added "0.1"}
  [:bytea i-account-root :bytea i-symbol-root :bytea i-value-root]
  (let [(:bytea v-environment) (-/account-value-environment-root i-account-root)
        (:bytea v-next-environment)
        (value/map-assoc v-environment i-symbol-root i-value-root)]
    (return (-/account-value-put
             (-/account-value-sequence-root i-account-root)
             v-next-environment
             (-/account-value-metadata-root i-account-root)
             (-/account-value-controller-root i-account-root)))))

(defn.pg ^{:- [:bytea]} account-value-define
  "Named semantic account-definition transition."
  {:added "0.1"}
  [:bytea i-account-root :bytea i-symbol-root :bytea i-value-root]
  (return (-/account-value-define-empty i-account-root i-symbol-root i-value-root)))

(defn.pg ^{:- [:bytea]} account-value-advance-sequence
  "Returns an immutable account successor with sequence incremented by one."
  {:added "0.2"}
  [:bytea i-account-root]
  (let [(:bytea v-sequence-root) (-/account-value-sequence-root i-account-root)
        (:bigint v-sequence) (value/integer-bigint v-sequence-root)
        (:bytea v-next-sequence) (value/put-integer-number (+ v-sequence 1))]
    (return (-/account-value-put
             v-next-sequence
             (-/account-value-environment-root i-account-root)
             (-/account-value-metadata-root i-account-root)
             (-/account-value-controller-root i-account-root)))))

(defn.pg ^{:- [:bytea]} account-value-lookup
  "Reads a symbol from the immutable semantic account environment."
  {:added "0.2"}
  [:bytea i-account-root :bytea i-symbol-root]
  (return (value/map-get (-/account-value-environment-root i-account-root)
                         i-symbol-root)))

(defn.pg account-get
  "Returns the current account projection."
  {:added "0.1"}
  [:bytea i-address]
  (let [o-row (pg/t:get -/Account
                        {:where {:address i-address}})]
    (return o-row)))

(defn.pg account-put
  "Upserts only the rebuildable account projection."
  {:added "0.1"}
  [:bytea i-address
   :bigint i-sequence
   :bytea i-state-root
   :bytea i-environment-root
   :bytea i-metadata-root
   :bytea i-controller]
  (let [o-row (pg/t:upsert -/Account
                           {:address i-address
                            :sequence i-sequence
                            :state-root i-state-root
                            :environment-root i-environment-root
                            :metadata-root i-metadata-root
                            :controller i-controller}
                           {:on-conflict #{:address}})]
    (return o-row)))

(defn.pg ^{:- [:bigint]} account-sequence
  "Returns the account sequence or zero for an absent account."
  {:added "0.1"}
  [:bytea i-address]
  (let [o-row (-/account-get i-address)]
    (cond [o-row :is-not-null]
          (return (:bigint (:->> o-row "sequence")))
          :else
          (return 0))))

(defn.pg ^{:- [:bytea]} account-environment
  "Returns the immutable environment root for an account."
  {:added "0.1"}
  [:bytea i-address]
  (let [o-row (-/account-get i-address)]
    (return (:bytea (:->> o-row "environment_root")))))

(defn.pg ^{:- [:bytea]} account-metadata
  "Returns the immutable metadata root for an account."
  {:added "0.1"}
  [:bytea i-address]
  (let [o-row (-/account-get i-address)]
    (return (:bytea (:->> o-row "metadata_root")))))

(defn.pg account-lookup
  "Named lookup alias used by state transition code."
  {:added "0.1"}
  [:bytea i-address]
  (return (-/account-get i-address)))

(defn.pg account-create
  "Creates an account projection at sequence zero."
  {:added "0.1"}
  [:bytea i-address
   :bytea i-state-root
   :bytea i-environment-root
   :bytea i-metadata-root
   :bytea i-controller]
  (return (-/account-put i-address 0 i-state-root i-environment-root
                         i-metadata-root i-controller)))

(defn.pg account-define
  "Persists a new environment root and advances the account sequence."
  {:added "0.1"}
  [:bytea i-address
   :bigint i-sequence
   :bytea i-state-root
   :bytea i-environment-root
   :bytea i-metadata-root
   :bytea i-controller]
  (return (-/account-put i-address i-sequence i-state-root i-environment-root
                         i-metadata-root i-controller)))

(defn.pg account-set-metadata
  "Persists metadata as a new immutable root without changing the environment."
  {:added "0.1"}
  [:bytea i-address
   :bigint i-sequence
   :bytea i-state-root
   :bytea i-environment-root
   :bytea i-metadata-root
   :bytea i-controller]
  (return (-/account-put i-address i-sequence i-state-root i-environment-root
                         i-metadata-root i-controller)))

(defn.pg definition-put
  "Updates the rebuildable account symbol index."
  {:added "0.1"}
  [:bytea i-address
   :bytea i-symbol-root
   :bytea i-value-root
   :bytea i-state-root]
  (let [o-row (pg/t:upsert -/Definition
                           {:address i-address
                            :symbol-root i-symbol-root
                            :value-root i-value-root
                            :state-root i-state-root})]
    (return o-row)))

(defn.pg definition-get
  "Looks up a definition from the explicit account projection."
  {:added "0.1"}
  [:bytea i-address :bytea i-symbol-root]
  (let [o-row (pg/t:get -/Definition
                        {:where {:address i-address
                                 :symbol-root i-symbol-root}})]
    (return o-row)))

(defn.pg account-advance-sequence
  "Advances an account sequence only from the expected predecessor."
  {:added "0.1"}
  [:bytea i-address :bigint i-expected-sequence]
  (let [o-row (-/account-get i-address)]
    (pg/assert [o-row :is-not-null]
               [:ledger/missing-account])
    (pg/assert (== (:bigint (:->> o-row "sequence"))
                   i-expected-sequence)
               [:ledger/sequence-conflict])
    (return (-/account-put
             i-address
             (+ i-expected-sequence 1)
             (:bytea (:->> o-row "state_root"))
             (:bytea (:->> o-row "environment_root"))
             (:bytea (:->> o-row "metadata_root"))
             (:bytea (:->> o-row "controller"))))))
