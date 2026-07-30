(ns gwdb.ledger.document
  (:require [tahto.core :as l]
            [postgres.core :as pg]
            [gwdb.ledger.cell :as cell]
            [gwdb.ledger.codec :as codec]
            [gwdb.ledger.crypto :as crypto]
            [gwdb.ledger.ot :as ot]
            [gwdb.ledger.syntax :as syntax]
            [gwdb.ledger.value :as value]))

(l/script :postgres
  {:require [[postgres.core :as pg]
             [gwdb.ledger.cell :as cell]
             [gwdb.ledger.codec :as codec]
             [gwdb.ledger.crypto :as crypto]
             [gwdb.ledger.ot :as ot]
             [gwdb.ledger.syntax :as syntax]
             [gwdb.ledger.value :as value]]
   :config {:dbname "gw-ledger-test"}
   :import [["pgcrypto"] ["pgsodium"]]
   :static {:application ["gw"]
            :all {:schema ["gw_ledger"]}}})

(deftype.pg Document
  "Mutable head projection over an append-only syntax document revision chain."
  {:added "0.5"}
  [:document-id {:type :text :primary true}
   :owner-key {:type :bytea :required true}
   :head-revision {:type :bytea :required true}
   :head-syntax {:type :bytea :required true}
   :next-order {:type :long :required true}
   :created-at {:type :time :required true :sql {:default (pg/time-us)}}])

(deftype.pg DocumentOperation
  "Projection of one immutable canonical AST edit operation."
  {:added "0.5"}
  [:operation-root {:type :bytea :primary true}
   :operation-kind {:type :text :required true}
   :target-id {:type :text}
   :parent-id {:type :text}
   :after-id {:type :text}
   :payload-root {:type :bytea}])

(deftype.pg DocumentRevision
  "Append-only canonical document history; status records transformed no-ops."
  {:added "0.5"}
  [:revision-root {:type :bytea :primary true}
   :document-id {:type :text :required true}
   :parent-revision {:type :bytea}
   :base-revision {:type :bytea}
   :accepted-order {:type :long :required true}
   :author-key {:type :bytea :required true}
   :operation-root {:type :bytea :required true}
   :syntax-root {:type :bytea :required true}
   :status {:type :text :required true}])

(defn.pg ^{:- [:boolean] :%% :sql :props [:immutable :parallel-safe]}
  document-operation-kind-valid
  {:added "0.5"}
  [:text i-kind]
  (or (== i-kind "create") (== i-kind "replace") (== i-kind "insert")
      (== i-kind "delete") (== i-kind "move")))

(defn.pg ^{:- [:text]}
  document-root-hex
  {:added "0.5"}
  [:bytea i-root]
  (return (pg/case [i-root :is-null] "-" :else (pg/encode i-root "hex"))))

(defn.pg ^{:- [:bytea]}
  document-operation-payload
  {:added "0.5"}
  [:text i-kind :text i-target-id :text i-parent-id :text i-after-id :bytea i-payload-root]
  (return (pg/decode
           (|| "R:document-operation:1:" i-kind ":"
               (pg/coalesce i-target-id "-") ":"
               (pg/coalesce i-parent-id "-") ":"
               (pg/coalesce i-after-id "-") ":"
               (-/document-root-hex i-payload-root))
           "escape")))

(defn.pg ^{:- [:bytea]}
  document-operation-put
  {:added "0.5"}
  [:text i-kind :text i-target-id :text i-parent-id :text i-after-id :bytea i-payload-root]
  (let [_ (pg/assert (-/document-operation-kind-valid i-kind) [:ledger/unknown-document-operation])
        _ (pg/assert (or [i-target-id :is-null] (ot/node-id-valid i-target-id))
                     [:ledger/invalid-ast-target])
        _ (pg/assert (or [i-parent-id :is-null] (ot/node-id-valid i-parent-id))
                     [:ledger/invalid-ast-parent])
        _ (pg/assert (or [i-after-id :is-null] (ot/node-id-valid i-after-id))
                     [:ledger/invalid-ast-anchor])
        _ (pg/assert (or [i-payload-root :is-null] (ot/syntax-root-valid i-payload-root))
                     [:ledger/invalid-ast-operation-payload])
        (:bytea v-payload) (-/document-operation-payload
                             i-kind i-target-id i-parent-id i-after-id i-payload-root)
        (:bytea v-root) (value/put-record v-payload)
        o-payload-ref (pg/case [i-payload-root :is-null] nil
                               :else (cell/cell-ref-put v-root 0 "payload" i-payload-root))
        o-row (pg/t:upsert -/DocumentOperation
                           {:operation-root v-root :operation-kind i-kind
                            :target-id i-target-id :parent-id i-parent-id
                            :after-id i-after-id :payload-root i-payload-root})]
    (return v-root)))

(defn.pg document-operation-get
  {:added "0.5"}
  [:bytea i-operation-root]
  (let [o-operation (pg/t:get -/DocumentOperation
                              {:where {:operation-root i-operation-root}})]
    (return o-operation)))

(defn.pg ^{:- [:bytea]}
  document-syntax-import
  "Rebuilds the disposable Syntax projection from authoritative HCP1 refs."
  {:added "0.6"}
  [:bytea i-syntax-root]
  (let [(:bytea v-syntax-root)
        (syntax/put-syntax
         (cell/cell-ref-child i-syntax-root 0 "value")
         (cell/cell-ref-child i-syntax-root 1 "metadata"))
        _ (pg/assert (== v-syntax-root i-syntax-root)
                     [:ledger/document-syntax-root-mismatch])]
    (return v-syntax-root)))

(defn.pg ^{:- [:bytea]}
  document-operation-import-replace
  "Rebuilds the disposable replace-operation projection from an imported HCP1
   graph and proves that its canonical root matches the signed operation."
  {:added "0.6"}
  [:bytea i-operation-root :text i-target-id :bytea i-payload-root]
  (let [(:bytea v-syntax-root) (-/document-syntax-import i-payload-root)
        (:bytea v-operation-root)
        (-/document-operation-put "replace" i-target-id nil nil i-payload-root)
        _ (pg/assert (== v-operation-root i-operation-root)
                     [:ledger/document-operation-root-mismatch])]
    (return v-operation-root)))

(defn.pg ^{:- [:bytea]}
  document-revision-payload
  {:added "0.5"}
  [:text i-document-id :bytea i-parent-revision :bytea i-base-revision
   :bigint i-order :bytea i-author-key :bytea i-operation-root
   :bytea i-syntax-root :text i-status]
  (return (pg/decode
           (|| "R:document-revision:1:" i-document-id ":"
               (-/document-root-hex i-parent-revision)
               (-/document-root-hex i-base-revision) i-order ":"
               (pg/encode i-author-key "hex") ":"
               (pg/encode i-operation-root "hex") ":"
               (pg/encode i-syntax-root "hex") ":" i-status)
           "escape")))

(defn.pg ^{:- [:bytea]}
  document-revision-put
  {:added "0.5"}
  [:text i-document-id :bytea i-parent-revision :bytea i-base-revision
   :bigint i-order :bytea i-author-key :bytea i-operation-root
   :bytea i-syntax-root :text i-status]
  (let [(:bytea v-payload)
        (-/document-revision-payload i-document-id i-parent-revision i-base-revision
                                     i-order i-author-key i-operation-root
                                     i-syntax-root i-status)
        (:bytea v-root) (value/put-record v-payload)
        o-parent-ref (pg/case [i-parent-revision :is-null] nil
                              :else (cell/cell-ref-put v-root 0 "parent" i-parent-revision))
        o-base-ref (pg/case [i-base-revision :is-null] nil
                            :else (cell/cell-ref-put v-root 1 "base" i-base-revision))
        o-operation-ref (cell/cell-ref-put v-root 2 "operation" i-operation-root)
        o-syntax-ref (cell/cell-ref-put v-root 3 "syntax" i-syntax-root)
        o-row (pg/t:upsert -/DocumentRevision
                           {:revision-root v-root :document-id i-document-id
                            :parent-revision i-parent-revision :base-revision i-base-revision
                            :accepted-order i-order :author-key i-author-key
                            :operation-root i-operation-root :syntax-root i-syntax-root
                            :status i-status})]
    (return v-root)))

(defn.pg document-get
  {:added "0.5"}
  [:text i-document-id]
  (let [o-document (pg/t:get -/Document {:where {:document-id i-document-id}})]
    (return o-document)))

(defn.pg document-lock
  {:added "0.5"}
  [:text i-document-id]
  (let [o-document (pg/t:get -/Document
                             {:where {:document-id i-document-id} :lock [:update]})]
    (return o-document)))

(defn.pg document-revision-get
  {:added "0.5"}
  [:bytea i-revision-root]
  (let [o-revision (pg/t:get -/DocumentRevision
                             {:where {:revision-root i-revision-root}})]
    (return o-revision)))

(defn.pg ^{:- [:bytea]}
  document-text-syntax
  "A deliberately small console bridge: a syntax-wrapped text leaf with a
   stable node id. Full Hara readers submit cell packs; the console can still
   create and replace this valid AST without inventing a second codec."
  {:added "0.5"}
  [:text i-node-id :text i-text]
  (let [_ (pg/assert (ot/node-id-valid i-node-id) [:ledger/invalid-ast-node-id])
        (:bytea v-meta) (value/put-map (pg/jsonb-build-array
                                        (pg/encode (value/put-keyword "node/id") "hex")
                                        (pg/encode (value/put-string i-node-id) "hex")))]
    (return (syntax/put-syntax (value/put-string i-text) v-meta))))

(defn.pg ^{:- [:bytea]}
  document-create
  {:added "0.5"}
  [:text i-document-id :bytea i-owner-key :bytea i-syntax-root]
  (let [_ (pg/assert (ot/node-id-valid i-document-id) [:ledger/invalid-document-id])
        _ (pg/assert (crypto/public-key-valid i-owner-key) [:ledger/invalid-document-owner])
        _ (pg/assert (ot/syntax-root-valid i-syntax-root) [:ledger/invalid-document-syntax])
        o-existing (-/document-get i-document-id)
        _ (pg/assert [o-existing :is-null] [:ledger/document-exists])
        (:bytea v-op) (-/document-operation-put "create" nil nil nil i-syntax-root)
        (:bytea v-revision)
        (-/document-revision-put i-document-id nil nil 0 i-owner-key v-op i-syntax-root "ok")
        o-row (pg/t:insert -/Document
                            {:document-id i-document-id :owner-key i-owner-key
                             :head-revision v-revision :head-syntax i-syntax-root
                             :next-order 1})]
    (return v-revision)))

(defn.pg ^{:- [:bytea]}
  document-apply-operation
  "Applies a canonical operation to the current head. A stale target deleted
   by an earlier accepted revision becomes an append-only `noop` revision."
  {:added "0.5"}
  [:text i-document-id :bytea i-base-revision :bytea i-author-key :bytea i-operation-root]
  (let [o-document (-/document-lock i-document-id)
        _ (pg/assert [o-document :is-not-null] [:ledger/missing-document])
        _ (pg/assert (== (:bytea (:->> o-document "owner_key")) i-author-key)
                     [:ledger/document-owner-required])
        o-base (-/document-revision-get i-base-revision)
        _ (pg/assert (and [o-base :is-not-null]
                          (== (:text (:->> o-base "document_id")) i-document-id))
                     [:ledger/invalid-document-base])
        o-operation (-/document-operation-get i-operation-root)
        _ (pg/assert [o-operation :is-not-null] [:ledger/missing-document-operation])
        (:bytea v-head-syntax) (:bytea (:->> o-document "head_syntax"))
        (:text v-kind) (:text (:->> o-operation "operation_kind"))
        _ (pg/assert (not (== v-kind "create")) [:ledger/unsupported-document-operation])
        (:text v-target) (:text (:->> o-operation "target_id"))
        (:text v-parent) (:text (:->> o-operation "parent_id"))
        (:text v-after) (:text (:->> o-operation "after_id"))
        (:bytea v-payload) (:bytea (:->> o-operation "payload_root"))
        (:bytea v-target-root) (pg/case [v-target :is-null] nil
                                        :else (ot/find-node v-head-syntax v-target))
        (:bytea v-parent-root) (pg/case [v-parent :is-null] nil
                                        :else (ot/find-node v-head-syntax v-parent))
        (:boolean v-noop)
        (or (and (or (== v-kind "replace") (== v-kind "delete") (== v-kind "move"))
                 [v-target-root :is-null])
            (and (or (== v-kind "insert") (== v-kind "move"))
                 [v-parent-root :is-null]))
        _ (pg/assert
           (or v-noop
               (not (== v-kind "delete"))
               (not (== (ot/node-id v-head-syntax) v-target)))
           [:ledger/cannot-delete-document-root])
        _ (pg/assert
           (or v-noop
               (not (== v-kind "insert"))
               [(ot/find-node v-head-syntax (ot/node-id v-payload)) :is-null])
           [:ledger/duplicate-ast-node-id])
        _ (pg/assert
           (or v-noop
               (not (== v-kind "move"))
               [(ot/find-node v-target-root v-parent) :is-null])
           [:ledger/ast-move-cycle])
        (:bytea v-next-syntax)
        (pg/case v-noop v-head-syntax
                 (== v-kind "replace") (ot/replace-node v-head-syntax v-target v-payload)
                 (== v-kind "delete") (ot/delete-node v-head-syntax v-target)
                 (== v-kind "insert") (ot/insert-child v-head-syntax v-parent v-after v-payload)
                 (== v-kind "move") (ot/insert-child
                                     (ot/delete-node v-head-syntax v-target)
                                     v-parent v-after v-target-root))
        (:text v-status) (pg/case v-noop "noop" :else "ok")
        (:bytea v-revision)
        (-/document-revision-put
         i-document-id (:bytea (:->> o-document "head_revision")) i-base-revision
         (:bigint (:->> o-document "next_order")) i-author-key i-operation-root
         v-next-syntax v-status)
        o-update (pg/t:update -/Document
                              {:set {:head-revision v-revision :head-syntax v-next-syntax
                                     :next-order (+ (:bigint (:->> o-document "next_order")) 1)}
                               :where {:document-id i-document-id}})]
    (return v-revision)))

(defn.pg ^{:- [:jsonb]}
  document-head
  {:added "0.5"}
  [:text i-document-id]
  (let [o-document (-/document-get i-document-id)
        _ (pg/assert [o-document :is-not-null] [:ledger/missing-document])]
    (return (pg/jsonb-build-object
             "document_id" i-document-id
             "head_revision" (pg/encode (:bytea (:->> o-document "head_revision")) "hex")
             "syntax_root" (pg/encode (:bytea (:->> o-document "head_syntax")) "hex")
             "next_order" (:bigint (:->> o-document "next_order"))))))
