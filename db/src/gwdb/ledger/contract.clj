(ns gwdb.ledger.contract
  (:require [tahto.core :as l]
            [postgres.core :as pg]
            [gwdb.ledger.account :as account]
            [gwdb.ledger.cell :as cell]
            [gwdb.ledger.codec :as codec]
            [gwdb.ledger.context :as context]
            [gwdb.ledger.function :as function]
            [gwdb.ledger.op :as op]
            [gwdb.ledger.runtime-profile :as runtime-profile]
            [gwdb.ledger.state :as state]
            [gwdb.ledger.value :as value]))

(l/script :postgres
  {:require [[postgres.core :as pg]
             [gwdb.ledger.account :as account]
             [gwdb.ledger.cell :as cell]
             [gwdb.ledger.codec :as codec]
             [gwdb.ledger.context :as context]
             [gwdb.ledger.function :as function]
             [gwdb.ledger.op :as op]
             [gwdb.ledger.runtime-profile :as runtime-profile]
             [gwdb.ledger.state :as state]
             [gwdb.ledger.value :as value]]
   :config {:dbname "gw-ledger-test"}
   :static {:application ["gw"]
            :all {:schema ["gw_ledger"]}}})

(defn.pg ^{:- [:bytea]}
  keyword-root
  {:added "0.9"}
  [:text i-name]
  (return (value/put-keyword i-name)))

(defn.pg ^{:- [:bytea]}
  field
  {:added "0.9"}
  [:bytea i-record-root :text i-name]
  (return
   (value/map-get i-record-root (-/keyword-root i-name))))

(defn.pg ^{:- [:bytea]}
  record-start
  {:added "0.9"}
  [:text i-kind]
  (return
   (value/map-assoc
    (value/put-map (pg/jsonb-build-array))
    (-/keyword-root "record/type")
    (-/keyword-root i-kind))))

(defn.pg ^{:- [:bytea]}
  record-assoc
  {:added "0.9"}
  [:bytea i-record-root :text i-name :bytea i-value-root]
  (return
   (value/map-assoc
    i-record-root (-/keyword-root i-name) i-value-root)))

(defn.pg ^{:- [:boolean]}
  record-kind
  {:added "0.9"}
  [:bytea i-record-root :text i-kind]
  (let [o-cell (cell/cell-by-hash i-record-root)]
    (return
     (and [o-cell :is-not-null]
          (== (:smallint (:->> o-cell "type_tag")) 11)
          (== (-/field i-record-root "record/type")
              (-/keyword-root i-kind))))))

(defn.pg ^{:- [:bytea]}
  optional-root
  {:added "0.9"}
  [:bytea i-root]
  (return
   (pg/case [i-root :is-null]
            (value/put-nil)
            :else i-root)))

(defn.pg ^{:- [:boolean]}
  function-arity
  {:added "0.9"}
  [:bytea i-function-root :integer i-arity]
  (let [o-function (function/function-get i-function-root)]
    (return
     (and [o-function :is-not-null]
          (function/function-valid i-function-root)
          (== (cell/cell-ref-count
               (:bytea (:->> o-function "parameters_root"))
               "element")
              i-arity)))))

(defn.pg ^{:- [:boolean]}
  views-valid-at
  {:added "0.9"}
  [:bytea i-views-root :integer i-position :integer i-count]
  (cond (>= i-position i-count)
        (return true)
        :else
        (let [(:bytea v-name-root)
              (cell/cell-ref-child i-views-root i-position "key")
              (:bytea v-function-root)
              (cell/cell-ref-child i-views-root i-position "value")]
          (return
           (and (== (cell/cell-type-tag v-name-root) 7)
                (-/function-arity v-function-root 1)
                (-/views-valid-at
                 i-views-root (+ i-position 1) i-count))))))

(defn.pg ^{:- [:boolean]}
  views-valid
  {:added "0.9"}
  [:bytea i-views-root]
  (let [o-views (cell/cell-by-hash i-views-root)]
    (return
     (and [o-views :is-not-null]
          (== (:smallint (:->> o-views "type_tag")) 11)
          (-/views-valid-at
           i-views-root 0
           (cell/cell-ref-count i-views-root "key"))))))

(defn.pg ^{:- [:bytea]}
  template-put
  "Commits an immutable reducer contract template."
  {:added "0.9"}
  [:bytea i-name-root
   :bytea i-version-root
   :bytea i-publisher-root
   :bytea i-init-root
   :bytea i-transition-root
   :bytea i-views-root
   :bytea i-source-root
   :bytea i-compiler-root
   :bytea i-runtime-root
   :bytea i-event-schema-root
   :bytea i-state-schema-root]
  (let [_ (pg/assert (== (cell/cell-type-tag i-name-root) 7)
                     [:ledger/contract-name-not-symbol])
        _ (pg/assert [(cell/cell-by-hash i-version-root) :is-not-null]
                     [:ledger/missing-contract-version])
        _ (pg/assert [(cell/cell-by-hash i-publisher-root) :is-not-null]
                     [:ledger/missing-contract-publisher])
        _ (pg/assert (-/function-arity i-init-root 1)
                     [:ledger/invalid-contract-init])
        _ (pg/assert (-/function-arity i-transition-root 2)
                     [:ledger/invalid-contract-transition])
        _ (pg/assert (-/views-valid i-views-root)
                     [:ledger/invalid-contract-views])
        _ (pg/assert [(cell/cell-by-hash i-source-root) :is-not-null]
                     [:ledger/missing-contract-source])
        _ (pg/assert [(cell/cell-by-hash i-compiler-root) :is-not-null]
                     [:ledger/missing-contract-compiler])
        _ (pg/assert (runtime-profile/runtime-root-valid i-runtime-root)
                     [:ledger/invalid-contract-runtime])
        _ (pg/assert [(cell/cell-by-hash i-event-schema-root) :is-not-null]
                     [:ledger/missing-contract-event-schema])
        _ (pg/assert [(cell/cell-by-hash i-state-schema-root) :is-not-null]
                     [:ledger/missing-contract-state-schema])
        (:bytea v-record) (-/record-start "contract-template")
        (:bytea v-name)
        (-/record-assoc v-record "contract/name" i-name-root)
        (:bytea v-version)
        (-/record-assoc v-name "contract/version" i-version-root)
        (:bytea v-publisher)
        (-/record-assoc v-version "contract/publisher" i-publisher-root)
        (:bytea v-init)
        (-/record-assoc v-publisher "contract/init" i-init-root)
        (:bytea v-transition)
        (-/record-assoc v-init "contract/transition" i-transition-root)
        (:bytea v-views)
        (-/record-assoc v-transition "contract/views" i-views-root)
        (:bytea v-source)
        (-/record-assoc v-views "contract/source" i-source-root)
        (:bytea v-compiler)
        (-/record-assoc v-source "contract/compiler" i-compiler-root)
        (:bytea v-runtime)
        (-/record-assoc v-compiler "contract/runtime" i-runtime-root)
        (:bytea v-event-schema)
        (-/record-assoc
         v-runtime "contract/event-schema" i-event-schema-root)]
    (return
     (-/record-assoc
      v-event-schema "contract/state-schema" i-state-schema-root))))

(defn.pg ^{:- [:boolean]}
  template-valid
  {:added "0.9"}
  [:bytea i-template-root]
  (let [_ (when (not (-/record-kind
                      i-template-root "contract-template"))
            (return false))
        (:bytea v-name-root)
        (-/field i-template-root "contract/name")
        (:bytea v-publisher-root)
        (-/field i-template-root "contract/publisher")
        (:bytea v-init-root)
        (-/field i-template-root "contract/init")
        (:bytea v-transition-root)
        (-/field i-template-root "contract/transition")
        (:bytea v-views-root)
        (-/field i-template-root "contract/views")
        (:bytea v-source-root)
        (-/field i-template-root "contract/source")
        (:bytea v-compiler-root)
        (-/field i-template-root "contract/compiler")
        (:bytea v-runtime-root)
        (-/field i-template-root "contract/runtime")
        (:bytea v-event-schema-root)
        (-/field i-template-root "contract/event-schema")
        (:bytea v-state-schema-root)
        (-/field i-template-root "contract/state-schema")]
    (return
     (and (== (cell/cell-type-tag v-name-root) 7)
          [(cell/cell-by-hash v-publisher-root) :is-not-null]
          (-/function-arity v-init-root 1)
          (-/function-arity v-transition-root 2)
          (-/views-valid v-views-root)
          [(cell/cell-by-hash v-source-root) :is-not-null]
          [(cell/cell-by-hash v-compiler-root) :is-not-null]
          (runtime-profile/runtime-root-valid v-runtime-root)
          [(cell/cell-by-hash v-event-schema-root) :is-not-null]
          [(cell/cell-by-hash v-state-schema-root) :is-not-null]))))

(defn.pg ^{:- [:bytea]}
  publication-put
  "Commits evidence that a verified account published one exact template root."
  {:added "0.9"}
  [:bytea i-template-root
   :bytea i-publisher-root
   :bytea i-alias-root
   :bytea i-transaction-root
   :bigint i-timestamp]
  (let [_ (pg/assert (-/template-valid i-template-root)
                     [:ledger/invalid-contract-template])
        _ (pg/assert (== (cell/cell-type-tag i-alias-root) 7)
                     [:ledger/contract-alias-not-symbol])
        (:bytea v-record) (-/record-start "contract-publication")
        (:bytea v-template)
        (-/record-assoc v-record "contract/template" i-template-root)
        (:bytea v-publisher)
        (-/record-assoc v-template "contract/publisher" i-publisher-root)
        (:bytea v-alias)
        (-/record-assoc v-publisher "contract/alias" i-alias-root)
        (:bytea v-transaction)
        (-/record-assoc
         v-alias "contract/transaction"
         (-/optional-root i-transaction-root))]
    (return
     (-/record-assoc
      v-transaction "contract/timestamp"
      (value/put-integer-number i-timestamp)))))

(defn.pg ^{:- [:bytea]}
  verified-event-put
  "Adds ledger-derived identity and ordering facts to an untrusted event payload."
  {:added "0.9"}
  [:bytea i-payload-root
   :bytea i-contract-root
   :bytea i-template-root
   :bytea i-signer-root
   :bytea i-transaction-root
   :bigint i-timestamp
   :bytea i-previous-head-root]
  (let [_ (pg/assert (== (cell/cell-type-tag i-payload-root) 11)
                     [:ledger/contract-event-not-map])
        (:bytea v-contract)
        (value/map-assoc
         i-payload-root (-/keyword-root "contract") i-contract-root)
        (:bytea v-template)
        (value/map-assoc
         v-contract (-/keyword-root "template") i-template-root)
        (:bytea v-signer)
        (value/map-assoc
         v-template (-/keyword-root "signer") i-signer-root)
        (:bytea v-transaction)
        (value/map-assoc
         v-signer (-/keyword-root "transaction")
         (-/optional-root i-transaction-root))
        (:bytea v-timestamp)
        (value/map-assoc
         v-transaction (-/keyword-root "timestamp")
         (value/put-integer-number i-timestamp))]
    (return
     (value/map-assoc
      v-timestamp (-/keyword-root "previous-head")
      i-previous-head-root))))

(defn.pg ^{:- [:bytea]}
  commit-put
  {:added "0.9"}
  [:bytea i-contract-root
   :bytea i-template-root
   :bytea i-parent-root
   :bytea i-event-root
   :bytea i-signer-root
   :bytea i-previous-state-root
   :bytea i-state-root
   :bytea i-transaction-root
   :bigint i-timestamp]
  (let [(:bytea v-record) (-/record-start "contract-commit")
        (:bytea v-contract)
        (-/record-assoc v-record "contract/address" i-contract-root)
        (:bytea v-template)
        (-/record-assoc v-contract "contract/template" i-template-root)
        (:bytea v-parent)
        (-/record-assoc v-template "contract/parent" i-parent-root)
        (:bytea v-event)
        (-/record-assoc v-parent "contract/event" i-event-root)
        (:bytea v-signer)
        (-/record-assoc v-event "contract/signer" i-signer-root)
        (:bytea v-before)
        (-/record-assoc
         v-signer "contract/previous-state" i-previous-state-root)
        (:bytea v-after)
        (-/record-assoc v-before "contract/state" i-state-root)
        (:bytea v-transaction)
        (-/record-assoc
         v-after "contract/transaction"
         (-/optional-root i-transaction-root))]
    (return
     (-/record-assoc
      v-transaction "contract/timestamp"
      (value/put-integer-number i-timestamp)))))

(defn.pg ^{:- [:bytea]}
  result-put
  {:added "0.9"}
  [:bytea i-contract-root
   :bytea i-head-root
   :bytea i-state-root
   :bytea i-result-root
   :boolean i-committed]
  (let [(:bytea v-record) (-/record-start "contract-result")
        (:bytea v-contract)
        (-/record-assoc v-record "contract/address" i-contract-root)
        (:bytea v-head)
        (-/record-assoc v-contract "contract/head" i-head-root)
        (:bytea v-state)
        (-/record-assoc v-head "contract/state" i-state-root)
        (:bytea v-result)
        (-/record-assoc v-state "contract/result" i-result-root)]
    (return
     (-/record-assoc
      v-result "contract/committed"
      (value/put-boolean i-committed)))))

(defn.pg ^{:- [:bytea]}
  template-symbol
  {:added "0.9"}
  []
  (return (value/put-symbol "ignatius.contract/template")))

(defn.pg ^{:- [:bytea]}
  state-symbol
  {:added "0.9"}
  []
  (return (value/put-symbol "ignatius.contract/state")))

(defn.pg ^{:- [:bytea]}
  head-symbol
  {:added "0.9"}
  []
  (return (value/put-symbol "ignatius.contract/head")))

(defn.pg ^{:- [:bytea]}
  history-symbol
  {:added "0.9"}
  []
  (return (value/put-symbol "ignatius.contract/history")))

(defn.pg ^{:- [:bytea]}
  creator-symbol
  {:added "0.9"}
  []
  (return (value/put-symbol "ignatius.contract/creator")))

(defn.pg ^{:- [:bytea]}
  instance-account-create
  {:added "0.9"}
  [:bytea i-creator-root
   :bytea i-template-root
   :bytea i-state-root
   :bytea i-head-root
   :bytea i-history-root]
  (let [(:bytea v-account)
        (account/account-value-create-actor
         i-creator-root i-creator-root)
        (:bytea v-template)
        (account/account-value-define
         v-account (-/template-symbol) i-template-root)
        (:bytea v-state)
        (account/account-value-define
         v-template (-/state-symbol) i-state-root)
        (:bytea v-head)
        (account/account-value-define
         v-state (-/head-symbol) i-head-root)
        (:bytea v-history)
        (account/account-value-define
         v-head (-/history-symbol) i-history-root)]
    (return
     (account/account-value-define
      v-history (-/creator-symbol) i-creator-root))))

(defn.pg ^{:- [:bytea]}
  instance-account-update
  {:added "0.9"}
  [:bytea i-account-root
   :bytea i-state-root
   :bytea i-head-root
   :bytea i-history-root]
  (let [(:bytea v-state)
        (account/account-value-define
         i-account-root (-/state-symbol) i-state-root)
        (:bytea v-head)
        (account/account-value-define
         v-state (-/head-symbol) i-head-root)]
    (return
     (account/account-value-define
      v-head (-/history-symbol) i-history-root))))

(defn.pg ^{:- [:bytea]}
  instance-binding
  {:added "0.9"}
  [:bytea i-state-root :bytea i-address-root :bytea i-symbol-root]
  (let [(:bytea v-account-root)
        (state/state-account-root i-state-root i-address-root)]
    (return
     (pg/case [v-account-root :is-null] nil
              :else
              (account/account-value-lookup
               v-account-root i-symbol-root)))))

(defn.pg ^{:- [:bytea]}
  instance-template
  {:added "0.9"}
  [:bytea i-state-root :bytea i-address-root]
  (return
   (-/instance-binding
    i-state-root i-address-root (-/template-symbol))))

(defn.pg ^{:- [:bytea]}
  instance-state
  {:added "0.9"}
  [:bytea i-state-root :bytea i-address-root]
  (return
   (-/instance-binding
    i-state-root i-address-root (-/state-symbol))))

(defn.pg ^{:- [:bytea]}
  instance-head
  {:added "0.9"}
  [:bytea i-state-root :bytea i-address-root]
  (return
   (-/instance-binding
    i-state-root i-address-root (-/head-symbol))))

(defn.pg ^{:- [:bytea]}
  instance-history
  {:added "0.9"}
  [:bytea i-state-root :bytea i-address-root]
  (return
   (-/instance-binding
    i-state-root i-address-root (-/history-symbol))))

(defn.pg ^{:- [:boolean]}
  instance-valid
  {:added "0.9"}
  [:bytea i-state-root :bytea i-address-root]
  (let [(:bytea v-template-root)
        (-/instance-template i-state-root i-address-root)
        (:bytea v-contract-state)
        (-/instance-state i-state-root i-address-root)
        (:bytea v-head-root)
        (-/instance-head i-state-root i-address-root)
        (:bytea v-history-root)
        (-/instance-history i-state-root i-address-root)
        o-history (cell/cell-by-hash v-history-root)]
    (return
     (and [v-template-root :is-not-null]
          [v-contract-state :is-not-null]
          [v-head-root :is-not-null]
          [o-history :is-not-null]
          (-/template-valid v-template-root)
          [(cell/cell-by-hash v-contract-state) :is-not-null]
          [(cell/cell-by-hash v-head-root) :is-not-null]
          (== (:smallint (:->> o-history "type_tag")) 10)))))

(defn.pg ^{:- [:text]}
  root-hex
  {:added "0.9"}
  [:bytea i-root]
  (return
   (pg/case [i-root :is-null] "-"
            :else (pg/encode i-root "hex"))))

(defn.pg ^{:- [:bytea]}
  address-payload
  {:added "0.9"}
  [:bytea i-context-root :bytea i-op-root]
  (let [o-context (context/context-get i-context-root)]
    (return
     (pg/decode
      (|| "R:contract-address:1:4:"
          (-/root-hex
           (:bytea (:->> o-context "transaction_root"))) ":"
          (-/root-hex
           (:bytea (:->> o-context "address"))) ":"
          (-/root-hex i-op-root) ":"
          (:text (:bigint (:->> o-context "cost_used"))))
      "escape"))))

(defn.pg ^{:- [:bytea]}
  address-root
  {:added "0.9"}
  [:bytea i-context-root :bytea i-op-root]
  (return
   (value/put-blob
    (codec/canonical-hash
     14 (-/address-payload i-context-root i-op-root)))))

(defn.pg ^{:- [:text]}
  special-name
  {:added "0.9"}
  [:bytea i-op-root]
  (let [o-op (op/op-get i-op-root)
        o-symbol
        (pg/case [o-op :is-null] nil
                 :else
                 (cell/cell-by-hash
                  (:bytea (:->> o-op "symbol_root"))))]
    (return
     (pg/case (or [o-op :is-null] [o-symbol :is-null])
              ""
              :else
              (pg/encode
               (:bytea (:->> o-symbol "payload")) "escape")))))

(defn.pg ^{:- [:bytea]}
  publish-op
  {:added "0.9"}
  [:bytea i-template-op-root :bytea i-alias-op-root]
  (return
   (op/put-op
    "special" nil (value/put-symbol "contract/publish")
    nil nil nil nil nil
    (pg/jsonb-build-array
     (pg/encode i-template-op-root "hex")
     (pg/encode i-alias-op-root "hex")))))

(defn.pg ^{:- [:bytea]}
  open-op
  {:added "0.9"}
  [:bytea i-template-op-root :bytea i-parameters-op-root]
  (return
   (op/put-op
    "special" nil (value/put-symbol "contract/open")
    nil nil nil nil nil
    (pg/jsonb-build-array
     (pg/encode i-template-op-root "hex")
     (pg/encode i-parameters-op-root "hex")))))

(defn.pg ^{:- [:bytea]}
  apply-op
  {:added "0.9"}
  [:bytea i-contract-op-root
   :bytea i-expected-head-op-root
   :bytea i-event-op-root]
  (return
   (op/put-op
    "special" nil (value/put-symbol "contract/apply")
    nil nil nil nil nil
    (pg/jsonb-build-array
     (pg/encode i-contract-op-root "hex")
     (pg/encode i-expected-head-op-root "hex")
     (pg/encode i-event-op-root "hex")))))

(defn.pg ^{:- [:bytea]}
  simulate-op
  {:added "0.9"}
  [:bytea i-contract-op-root :bytea i-event-op-root]
  (return
   (op/put-op
    "special" nil (value/put-symbol "contract/simulate")
    nil nil nil nil nil
    (pg/jsonb-build-array
     (pg/encode i-contract-op-root "hex")
     (pg/encode i-event-op-root "hex")))))

(defn.pg ^{:- [:bytea]}
  state-op
  {:added "0.9"}
  [:bytea i-contract-op-root]
  (return
   (op/put-op
    "special" nil (value/put-symbol "contract/state")
    nil nil nil nil nil
    (pg/jsonb-build-array
     (pg/encode i-contract-op-root "hex")))))

(defn.pg ^{:- [:bytea]}
  history-op
  {:added "0.9"}
  [:bytea i-contract-op-root]
  (return
   (op/put-op
    "special" nil (value/put-symbol "contract/history")
    nil nil nil nil nil
    (pg/jsonb-build-array
     (pg/encode i-contract-op-root "hex")))))

(defn.pg ^{:- [:bytea]}
  view-op
  {:added "0.9"}
  [:bytea i-contract-op-root :bytea i-view-symbol-root]
  (return
   (op/put-op
    "special" i-view-symbol-root (value/put-symbol "contract/view")
    nil nil nil nil nil
    (pg/jsonb-build-array
     (pg/encode i-contract-op-root "hex")))))
