(ns gwdb.ledger.ot
  (:require [tahto.core :as l]
            [postgres.core :as pg]
            [gwdb.ledger.cell :as cell]
            [gwdb.ledger.syntax :as syntax]
            [gwdb.ledger.value :as value]))

;; OT operates only on explicit syntax values.  The semantic value graph stays
;; immutable: every edit rebuilds just the changed syntax path and shares every
;; unaffected Hara cell.
(l/script :postgres
  {:require [[postgres.core :as pg]
             [gwdb.ledger.cell :as cell]
             [gwdb.ledger.syntax :as syntax]
             [gwdb.ledger.value :as value]]
   :config {:dbname "gw-ledger-test"}
   :import [["pgcrypto"]]
   :static {:application ["gw"]
            :all {:schema ["gw_ledger"]}}})

(defn.pg ^{:- [:boolean] :%% :sql :props [:immutable :parallel-safe]}
  node-id-valid
  {:added "0.5"}
  [:text i-node-id]
  (and
   [(pg/regexp-match
     i-node-id
     "^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
    :is-not-null]))

(defn.pg ^{:- [:text]}
  node-id
  "Reads the required UUIDv7 from `:node/id` syntax metadata."
  {:added "0.5"}
  [:bytea i-syntax-root]
  (let [(:bytea v-id-root)
        (value/map-get (syntax/syntax-metadata-root i-syntax-root)
                       (value/put-keyword "node/id"))
        o-id (cell/cell-by-hash v-id-root)
        _ (pg/assert (and [o-id :is-not-null]
                          (== (:smallint (:->> o-id "type_tag")) 5))
                     [:ledger/missing-ast-node-id])
        (:text v-node-id) (convert-from (:bytea (:->> o-id "payload")) "UTF8")
        _ (pg/assert (-/node-id-valid v-node-id) [:ledger/invalid-ast-node-id])]
    (return v-node-id)))

(defn.pg ^{:- [:boolean]}
  syntax-root-valid
  {:added "0.5"}
  [:bytea i-root]
  (let [o-cell (cell/cell-by-hash i-root)]
    (return (and [o-cell :is-not-null]
                 (== (:smallint (:->> o-cell "type_tag")) 13)))))

(defn.pg ^{:- [:integer]}
  node-sequence-tag
  {:added "0.5"}
  [:bytea i-syntax-root]
  (let [(:bytea v-value-root) (syntax/syntax-value-root i-syntax-root)
        (:integer v-tag) (cell/cell-type-tag v-value-root)]
    (return v-tag)))

(defn.pg ^{:- [:integer]}
  node-child-count
  {:added "0.5"}
  [:bytea i-syntax-root]
  (let [(:integer v-tag) (-/node-sequence-tag i-syntax-root)]
    (cond (or (== v-tag 9) (== v-tag 10))
          (return (cell/cell-ref-count (syntax/syntax-value-root i-syntax-root) "element"))
          :else (return 0))))

(defn.pg ^{:- [:bytea]}
  node-child-root
  {:added "0.5"}
  [:bytea i-syntax-root :integer i-position]
  (return (cell/cell-ref-child (syntax/syntax-value-root i-syntax-root)
                               i-position "element")))

(defn.pg ^{:- [:bytea]}
  find-node-at
  "Depth-first deterministic node-ID lookup over syntax-wrapped list/vector
   children."
  {:added "0.5"}
  [:bytea i-syntax-root :text i-node-id :integer i-position :integer i-count]
  (cond (== (-/node-id i-syntax-root) i-node-id) (return i-syntax-root)
        (>= i-position i-count) (return nil)
        :else
        (let [(:bytea v-child) (-/node-child-root i-syntax-root i-position)
              _ (pg/assert (-/syntax-root-valid v-child)
                           [:ledger/ast-child-not-syntax])
              (:bytea v-found)
              (-/find-node-at v-child i-node-id 0 (-/node-child-count v-child))]
          (cond [v-found :is-not-null] (return v-found)
                :else (return (-/find-node-at
                               i-syntax-root i-node-id (+ i-position 1) i-count))))))

(defn.pg ^{:- [:bytea]}
  find-node
  {:added "0.5"}
  [:bytea i-syntax-root :text i-node-id]
  (return (-/find-node-at i-syntax-root i-node-id 0
                          (-/node-child-count i-syntax-root))))

(defn.pg ^{:- [:bytea]}
  replace-node-at
  {:added "0.5"}
  [:bytea i-syntax-root :text i-target-id :bytea i-replacement-root
   :integer i-position :integer i-count :jsonb i-out]
  (cond (== i-position -1)
        (cond (== (-/node-id i-syntax-root) i-target-id)
              (do (pg/assert (== (-/node-id i-replacement-root) i-target-id)
                             [:ledger/ast-replacement-id-mismatch])
                  (return i-replacement-root))
              :else
              (let [(:integer v-count) (-/node-child-count i-syntax-root)]
                (cond (== v-count 0) (return i-syntax-root)
                      :else (return (-/replace-node-at i-syntax-root i-target-id i-replacement-root
                                                       0 v-count (pg/jsonb-build-array))))))
        (>= i-position i-count)
        (let [(:integer v-tag) (-/node-sequence-tag i-syntax-root)
              (:bytea v-value) (pg/case (== v-tag 9) (value/put-list i-out)
                                         :else (value/put-vector i-out))]
          (return (syntax/put-syntax v-value (syntax/syntax-metadata-root i-syntax-root))))
        :else
        (let [(:bytea v-child) (-/node-child-root i-syntax-root i-position)
              (:bytea v-next-child) (-/replace-node-at v-child i-target-id i-replacement-root
                                                       -1 0 (pg/jsonb-build-array))
              (:jsonb v-next-out)
              (|| i-out (pg/jsonb-build-array (pg/encode v-next-child "hex")))]
          (return (-/replace-node-at
                   i-syntax-root i-target-id i-replacement-root
                   (+ i-position 1) i-count v-next-out)))))

(defn.pg ^{:- [:bytea]}
  rebuild-sequence-node
  {:added "0.5"}
  [:bytea i-syntax-root :jsonb i-child-roots]
  (let [(:integer v-tag) (-/node-sequence-tag i-syntax-root)
        _ (pg/assert (or (== v-tag 9) (== v-tag 10))
                     [:ledger/ast-node-not-sequence])
        (:bytea v-value-root)
        (pg/case (== v-tag 9) (value/put-list i-child-roots)
                 :else (value/put-vector i-child-roots))]
    (return (syntax/put-syntax v-value-root
                               (syntax/syntax-metadata-root i-syntax-root)))))

(defn.pg ^{:- [:bytea]}
  replace-node
  "Returns a structurally shared successor tree. The replacement must retain
   the target UUID so later operations keep addressing the same syntax node."
  {:added "0.5"}
  [:bytea i-syntax-root :text i-target-id :bytea i-replacement-root]
  (let [_ (pg/assert (-/syntax-root-valid i-syntax-root) [:ledger/invalid-ast-root])
        _ (pg/assert (-/syntax-root-valid i-replacement-root) [:ledger/invalid-ast-replacement])]
    (return (-/replace-node-at i-syntax-root i-target-id i-replacement-root
                               -1 0 (pg/jsonb-build-array)))))

(defn.pg ^{:- [:bytea]}
  delete-node-at
  {:added "0.5"}
  [:bytea i-syntax-root :text i-target-id :integer i-position :integer i-count :jsonb i-out]
  (cond (== i-position -1)
        (let [(:integer v-count) (-/node-child-count i-syntax-root)]
          (cond (== v-count 0) (return i-syntax-root)
                :else (return (-/delete-node-at i-syntax-root i-target-id 0 v-count
                                                 (pg/jsonb-build-array)))))
        (>= i-position i-count)
        (let [(:integer v-tag) (-/node-sequence-tag i-syntax-root)
              (:bytea v-value) (pg/case (== v-tag 9) (value/put-list i-out)
                                         :else (value/put-vector i-out))]
          (return (syntax/put-syntax v-value (syntax/syntax-metadata-root i-syntax-root))))
        :else
        (let [(:bytea v-child) (-/node-child-root i-syntax-root i-position)
              (:boolean v-delete) (== (-/node-id v-child) i-target-id)
              (:bytea v-next-child) (pg/case v-delete nil :else
                                            (-/delete-node-at v-child i-target-id -1 0
                                                              (pg/jsonb-build-array)))
              (:jsonb v-next-out)
              (pg/case v-delete i-out :else
                       (|| i-out (pg/jsonb-build-array (pg/encode v-next-child "hex"))))]
          (return (-/delete-node-at
                   i-syntax-root i-target-id (+ i-position 1) i-count v-next-out)))))

(defn.pg ^{:- [:bytea]}
  delete-node
  "Deletes a non-root node. Root deletion is intentionally rejected by the
   document layer; deletion wins when a stale operation targets a removed ID."
  {:added "0.5"}
  [:bytea i-syntax-root :text i-target-id]
  (return (-/delete-node-at i-syntax-root i-target-id -1 0 (pg/jsonb-build-array))))

(defn.pg ^{:- [:jsonb]}
  insert-child-roots
  {:added "0.5"}
  [:bytea i-parent-root :text i-after-id :bytea i-new-child-root
   :integer i-position :integer i-count :jsonb i-out :boolean i-inserted]
  (cond (>= i-position i-count)
        (return (pg/case i-inserted i-out :else
                         (|| i-out (pg/jsonb-build-array (pg/encode i-new-child-root "hex")))))
        :else
        (let [(:bytea v-child) (-/node-child-root i-parent-root i-position)
              (:jsonb v-with-child) (|| i-out (pg/jsonb-build-array (pg/encode v-child "hex")))
              (:boolean v-match) (and [i-after-id :is-not-null]
                                       (== (-/node-id v-child) i-after-id))
              (:jsonb v-next-out)
              (pg/case (and (not i-inserted) v-match)
                       (|| v-with-child (pg/jsonb-build-array (pg/encode i-new-child-root "hex")))
                       :else v-with-child)]
          (return (-/insert-child-roots
                   i-parent-root i-after-id i-new-child-root
                   (+ i-position 1) i-count v-next-out (or i-inserted v-match))))))

(defn.pg ^{:- [:bytea]}
  insert-child-at-parent
  "Inserts after a stable sibling anchor. NULL means start; unknown anchors
   append after the current last child, preserving an accepted offline edit."
  {:added "0.5"}
  [:bytea i-parent-root :text i-after-id :bytea i-new-child-root]
  (let [(:integer v-tag) (-/node-sequence-tag i-parent-root)
        _ (pg/assert (or (== v-tag 9) (== v-tag 10))
                     [:ledger/ast-parent-not-sequence])
        (:integer v-count) (-/node-child-count i-parent-root)
        (:jsonb v-roots)
        (pg/case [i-after-id :is-null]
                 (|| (pg/jsonb-build-array (pg/encode i-new-child-root "hex"))
                     (-/insert-child-roots i-parent-root i-after-id i-new-child-root
                                            0 v-count (pg/jsonb-build-array) true))
                 :else (-/insert-child-roots i-parent-root i-after-id i-new-child-root
                                             0 v-count (pg/jsonb-build-array) false))]
    (return (-/rebuild-sequence-node i-parent-root v-roots))))

(defn.pg ^{:- [:bytea]}
  insert-child
  {:added "0.5"}
  [:bytea i-syntax-root :text i-parent-id :text i-after-id :bytea i-new-child-root]
  (let [_ (pg/assert (-/syntax-root-valid i-new-child-root) [:ledger/invalid-ast-insert])
        (:bytea v-parent-root) (-/find-node i-syntax-root i-parent-id)
        _ (pg/assert [v-parent-root :is-not-null] [:ledger/missing-ast-parent])
        (:bytea v-parent-next) (-/insert-child-at-parent v-parent-root i-after-id i-new-child-root)]
    (return (-/replace-node i-syntax-root i-parent-id v-parent-next))))
