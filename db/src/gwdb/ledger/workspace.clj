(ns gwdb.ledger.workspace
  (:require [tahto.core :as l]
            [postgres.core :as pg]
            [gwdb.ledger.cell :as cell]
            [gwdb.ledger.value :as value]))

(l/script :postgres
  {:require [[postgres.core :as pg]
             [gwdb.ledger.cell :as cell]
             [gwdb.ledger.value :as value]]
   :config {:dbname "gw-ledger-test"}
   :static {:application ["gw"]
            :all {:schema ["gw_ledger"]}}})

(deftype.pg WorkspaceCommit
  "Rebuildable projection of one canonical workspace commit candidate."
  {:added "0.11"}
  [:commit-root              {:type :bytea :primary true}
   :workspace-id-root        {:type :bytea :required true}
   :workspace-root           {:type :bytea}
   :state-root               {:type :bytea :required true}
   :operation-root           {:type :bytea}
   :merge-base-root          {:type :bytea}
   :merge-policy-root        {:type :bytea}
   :author-evidence-root     {:type :bytea :required true}
   :execution-provenance-root {:type :bytea}
   :parent-count             {:type :integer :required true}])

(deftype.pg WorkspaceCommitParent
  "Ordered parent roots derived from a canonical workspace commit."
  {:added "0.11"}
  [:commit-root {:type :bytea :required true :primary true}
   :position    {:type :integer :required true :primary true}
   :parent-root {:type :bytea :required true}])

(defn.pg ^{:- [:bytea]}
  keyword-root
  {:added "0.11"}
  [:text i-name]
  (return (value/put-keyword i-name)))

(defn.pg ^{:- [:bytea]}
  field
  {:added "0.11"}
  [:bytea i-record-root :text i-name]
  (return
   (value/map-get i-record-root (-/keyword-root i-name))))

(defn.pg ^{:- [:bytea]}
  optional-field
  "Converts a canonical HCV1 nil field to SQL null."
  {:added "0.11"}
  [:bytea i-record-root :text i-name]
  (let [(:bytea v-root) (-/field i-record-root i-name)]
    (return
     (pg/case (== (cell/cell-type-tag v-root) 0)
              nil
              :else v-root))))

(defn.pg ^{:- [:boolean]}
  record-kind
  {:added "0.11"}
  [:bytea i-record-root :text i-kind]
  (let [o-cell (cell/cell-by-hash i-record-root)]
    (return
     (and [o-cell :is-not-null]
          (== (:smallint (:->> o-cell "type_tag")) 11)
          (== (-/field i-record-root "record/type")
              (-/keyword-root i-kind))))))

(defn.pg ^{:- [:boolean]}
  record-version-one
  {:added "0.11"}
  [:bytea i-record-root]
  (let [(:bytea v-version-root)
        (-/field i-record-root "record/version")]
    (return
     (and [v-version-root :is-not-null]
          (== (cell/cell-type-tag v-version-root) 3)
          (== (value/integer-bigint v-version-root) 1)))))

(defn.pg ^{:- [:bytea]}
  optional-root
  {:added "0.11"}
  [:bytea i-root]
  (return
   (pg/case [i-root :is-null]
            (value/put-nil)
            :else i-root)))

(defn.pg ^{:- [:bytea]}
  record-start
  {:added "0.11"}
  [:text i-kind]
  (return
   (value/map-assoc
    (value/put-map (pg/jsonb-build-array))
    (-/keyword-root "record/type")
    (-/keyword-root i-kind))))

(defn.pg ^{:- [:bytea]}
  record-assoc
  {:added "0.11"}
  [:bytea i-record-root :text i-name :bytea i-value-root]
  (return
   (value/map-assoc
    i-record-root (-/keyword-root i-name) i-value-root)))

(defn.pg ^{:- [:bytea]}
  workspace-commit-value
  "Constructs the canonical HCV1 workspace commit candidate value."
  {:added "0.11"}
  [:bytea i-workspace-id-root
   :bytea i-workspace-root
   :bytea i-parent-roots-root
   :bytea i-state-root
   :bytea i-operation-root
   :bytea i-merge-base-root
   :bytea i-merge-policy-root
   :bytea i-author-evidence-root
   :bytea i-execution-provenance-root
   :bytea i-metadata-root
   :bytea i-extensions-root]
  (let [(:bytea v-record)
        (-/record-start "workspace/commit-candidate")
        (:bytea v-version)
        (-/record-assoc
         v-record "record/version" (value/put-integer-number 1))
        (:bytea v-extensions)
        (-/record-assoc
         v-version "record/extensions" i-extensions-root)
        (:bytea v-workspace-id)
        (-/record-assoc
         v-extensions "workspace/id" i-workspace-id-root)
        (:bytea v-workspace)
        (-/record-assoc
         v-workspace-id "workspace/root"
         (-/optional-root i-workspace-root))
        (:bytea v-parents)
        (-/record-assoc
         v-workspace "commit/parent-roots" i-parent-roots-root)
        (:bytea v-state)
        (-/record-assoc v-parents "commit/state-root" i-state-root)
        (:bytea v-operation)
        (-/record-assoc
         v-state "commit/operation-root"
         (-/optional-root i-operation-root))
        (:bytea v-merge-base)
        (-/record-assoc
         v-operation "commit/merge-base-root"
         (-/optional-root i-merge-base-root))
        (:bytea v-merge-policy)
        (-/record-assoc
         v-merge-base "commit/merge-policy-root"
         (-/optional-root i-merge-policy-root))
        (:bytea v-author)
        (-/record-assoc
         v-merge-policy "commit/author-evidence"
         i-author-evidence-root)
        (:bytea v-provenance)
        (-/record-assoc
         v-author "commit/execution-provenance"
         (-/optional-root i-execution-provenance-root))]
    (return
     (-/record-assoc
      v-provenance "commit/metadata" i-metadata-root))))

(defn.pg workspace-commit-row
  {:added "0.11"}
  [:bytea i-commit-root]
  (return
   (pg/t:get -/WorkspaceCommit
             {:where {:commit-root i-commit-root}})))

(defn.pg ^{:- [:integer]}
  workspace-commit-parent-count
  {:added "0.11"}
  [:bytea i-commit-root]
  (return
   (pg/t:count -/WorkspaceCommitParent
               {:where {:commit-root i-commit-root}})))

(defn.pg ^{:- [:bytea]}
  workspace-commit-parent-root
  {:added "0.11"}
  [:bytea i-commit-root :integer i-position]
  (let [o-row
        (pg/t:get -/WorkspaceCommitParent
                  {:where {:commit-root i-commit-root
                           :position i-position}})]
    (return
     (pg/case [o-row :is-null] nil
              :else (:bytea (:->> o-row "parent_root"))))))

(defn.pg ^{:- [:boolean]}
  parent-seen-before
  {:added "0.11"}
  [:bytea i-parent-vector-root
   :integer i-position
   :bytea i-parent-root]
  (cond (<= i-position 0)
        (return false)

        :else
        (let [(:integer v-previous) (- i-position 1)
              (:bytea v-root)
              (cell/cell-ref-child
               i-parent-vector-root v-previous "element")]
          (return
           (or (== v-root i-parent-root)
               (-/parent-seen-before
                i-parent-vector-root v-previous i-parent-root))))))

(defn.pg ^{:- [:text]}
  parent-error-at
  {:added "0.11"}
  [:bytea i-commit-root
   :bytea i-workspace-id-root
   :bytea i-parent-vector-root
   :integer i-position
   :integer i-count]
  (cond (>= i-position i-count)
        (return nil)

        :else
        (let [(:bytea v-parent-root)
              (cell/cell-ref-child
               i-parent-vector-root i-position "element")
              o-parent (-/workspace-commit-row v-parent-root)]
          (cond (== v-parent-root i-commit-root)
                (return "workspace/self-parent")

                (-/parent-seen-before
                 i-parent-vector-root i-position v-parent-root)
                (return "workspace/duplicate-parent-root")

                [o-parent :is-null]
                (return "workspace/missing-parent-commit")

                (not
                 (== i-workspace-id-root
                     (:bytea (:->> o-parent "workspace_id_root"))))
                (return "workspace/parent-workspace-mismatch")

                :else
                (return
                 (-/parent-error-at
                  i-commit-root i-workspace-id-root
                  i-parent-vector-root (+ i-position 1) i-count))))))

(defn.pg ^{:- [:boolean]}
  workspace-commit-ancestor
  "Checks ancestry in the verified parent-before-child projection."
  {:added "0.11"}
  [:bytea i-ancestor-root :bytea i-descendant-root]
  (cond (== i-ancestor-root i-descendant-root)
        (return true)

        [(-/workspace-commit-row i-descendant-root) :is-null]
        (return false)

        :else
        (return
         (-/workspace-commit-ancestor-at
          i-ancestor-root i-descendant-root 0
          (-/workspace-commit-parent-count i-descendant-root)))))

(defn.pg ^{:- [:boolean]}
  workspace-commit-ancestor-at
  {:added "0.11"}
  [:bytea i-ancestor-root
   :bytea i-descendant-root
   :integer i-position
   :integer i-count]
  (cond (>= i-position i-count)
        (return false)

        :else
        (let [(:bytea v-parent-root)
              (-/workspace-commit-parent-root
               i-descendant-root i-position)]
          (return
           (or (== i-ancestor-root v-parent-root)
               (-/workspace-commit-ancestor
                i-ancestor-root v-parent-root)
               (-/workspace-commit-ancestor-at
                i-ancestor-root i-descendant-root
                (+ i-position 1) i-count))))))

(defn.pg ^{:- [:boolean]}
  merge-base-valid-at
  {:added "0.11"}
  [:bytea i-merge-base-root
   :bytea i-parent-vector-root
   :integer i-position
   :integer i-count]
  (cond (>= i-position i-count)
        (return true)

        :else
        (let [(:bytea v-parent-root)
              (cell/cell-ref-child
               i-parent-vector-root i-position "element")]
          (return
           (and
            (-/workspace-commit-ancestor
             i-merge-base-root v-parent-root)
            (-/merge-base-valid-at
             i-merge-base-root i-parent-vector-root
             (+ i-position 1) i-count))))))

(defn.pg ^{:- [:text]}
  workspace-commit-error
  "Returns the first canonical or graph validation failure, or SQL null."
  {:added "0.11"}
  [:bytea i-commit-root]
  (cond (not (-/record-kind
              i-commit-root "workspace/commit-candidate"))
        (return "workspace/invalid-commit-record")

        (not (-/record-version-one i-commit-root))
        (return "workspace/unsupported-commit-version")

        :else
        (let [(:bytea v-workspace-id-root)
              (-/field i-commit-root "workspace/id")
              (:bytea v-parent-vector-root)
              (-/field i-commit-root "commit/parent-roots")
              (:bytea v-state-root)
              (-/field i-commit-root "commit/state-root")
              (:bytea v-author-root)
              (-/field i-commit-root "commit/author-evidence")
              (:bytea v-merge-base-root)
              (-/optional-field i-commit-root "commit/merge-base-root")
              (:bytea v-merge-policy-root)
              (-/optional-field i-commit-root "commit/merge-policy-root")
              o-parent-vector (cell/cell-by-hash v-parent-vector-root)
              (:integer v-parent-count)
              (pg/case [o-parent-vector :is-null] -1
                       :else
                       (cell/cell-ref-count
                        v-parent-vector-root "element"))]
          (cond [(cell/cell-by-hash v-workspace-id-root) :is-null]
                (return "workspace/missing-workspace-id")

                (or [o-parent-vector :is-null]
                    (not
                     (== (:smallint (:->> o-parent-vector "type_tag")) 10)))
                (return "workspace/parents-not-vector")

                [(cell/cell-by-hash v-state-root) :is-null]
                (return "workspace/missing-state-root")

                (not (-/record-kind
                      v-author-root "ledger/evidence"))
                (return "workspace/invalid-author-evidence")

                [(cell/cell-by-hash
                  (-/field v-author-root "ledger/signer")) :is-null]
                (return "workspace/missing-author-signer")

                :else
                (let [(:text v-parent-error)
                      (-/parent-error-at
                       i-commit-root v-workspace-id-root
                       v-parent-vector-root 0 v-parent-count)]
                  (cond [v-parent-error :is-not-null]
                        (return v-parent-error)

                        (>= v-parent-count 2)
                        (cond [v-merge-base-root :is-null]
                              (return "workspace/missing-merge-base")

                              [v-merge-policy-root :is-null]
                              (return "workspace/missing-merge-policy")

                              [(-/workspace-commit-row
                                v-merge-base-root) :is-null]
                              (return "workspace/unknown-merge-base")

                              (not
                               (-/merge-base-valid-at
                                v-merge-base-root
                                v-parent-vector-root 0 v-parent-count))
                              (return "workspace/invalid-merge-base")

                              :else
                              (return nil))

                        (or [v-merge-base-root :is-not-null]
                            [v-merge-policy-root :is-not-null])
                        (return "workspace/non-merge-has-merge-fields")

                        :else
                        (return nil)))))))

(defn.pg ^{:- [:boolean]}
  projection-parents-valid-at
  {:added "0.11"}
  [:bytea i-commit-root
   :bytea i-parent-vector-root
   :integer i-position
   :integer i-count]
  (cond (>= i-position i-count)
        (return true)

        :else
        (return
         (and
          (== (-/workspace-commit-parent-root
               i-commit-root i-position)
              (cell/cell-ref-child
               i-parent-vector-root i-position "element"))
          (-/projection-parents-valid-at
           i-commit-root i-parent-vector-root
           (+ i-position 1) i-count)))))

(defn.pg ^{:- [:boolean]}
  workspace-commit-valid
  "Verifies a projection against its immutable canonical map and parents."
  {:added "0.11"}
  [:bytea i-commit-root]
  (let [o-row (-/workspace-commit-row i-commit-root)]
    (when [o-row :is-null]
      (return false))
    (let [(:bytea v-parent-vector-root)
          (-/field i-commit-root "commit/parent-roots")
          (:integer v-parent-count)
          (cell/cell-ref-count v-parent-vector-root "element")]
      (return
       (and [(-/workspace-commit-error i-commit-root) :is-null]
            (== (:bytea (:->> o-row "workspace_id_root"))
                (-/field i-commit-root "workspace/id"))
            (== (:bytea (:->> o-row "workspace_root"))
                (-/optional-field i-commit-root "workspace/root"))
            (== (:bytea (:->> o-row "state_root"))
                (-/field i-commit-root "commit/state-root"))
            (== (:bytea (:->> o-row "operation_root"))
                (-/optional-field i-commit-root "commit/operation-root"))
            (== (:bytea (:->> o-row "merge_base_root"))
                (-/optional-field i-commit-root "commit/merge-base-root"))
            (== (:bytea (:->> o-row "merge_policy_root"))
                (-/optional-field i-commit-root "commit/merge-policy-root"))
            (== (:bytea (:->> o-row "author_evidence_root"))
                (-/field i-commit-root "commit/author-evidence"))
            (== (:bytea (:->> o-row "execution_provenance_root"))
                (-/optional-field
                 i-commit-root "commit/execution-provenance"))
            (== (:integer (:->> o-row "parent_count"))
                v-parent-count)
            (== (-/workspace-commit-parent-count i-commit-root)
                v-parent-count)
            (-/projection-parents-valid-at
             i-commit-root v-parent-vector-root 0 v-parent-count))))))

(defn.pg ^{:- [:bytea]}
  workspace-commit-import
  "Validates and projects one canonical workspace commit idempotently."
  {:added "0.11"}
  [:bytea i-commit-root]
  (let [o-existing (-/workspace-commit-row i-commit-root)]
    (when [o-existing :is-not-null]
      (pg/assert (-/workspace-commit-valid i-commit-root)
                 [:ledger/workspace-commit-projection-conflict])
      (return i-commit-root))
    (let [(:text v-error) (-/workspace-commit-error i-commit-root)
          _ (pg/assert [v-error :is-null]
                       [:ledger/invalid-workspace-commit v-error])
          (:bytea v-workspace-id-root)
          (-/field i-commit-root "workspace/id")
          (:bytea v-workspace-root)
          (-/optional-field i-commit-root "workspace/root")
          (:bytea v-parent-vector-root)
          (-/field i-commit-root "commit/parent-roots")
          (:bytea v-state-root)
          (-/field i-commit-root "commit/state-root")
          (:bytea v-operation-root)
          (-/optional-field i-commit-root "commit/operation-root")
          (:bytea v-merge-base-root)
          (-/optional-field i-commit-root "commit/merge-base-root")
          (:bytea v-merge-policy-root)
          (-/optional-field i-commit-root "commit/merge-policy-root")
          (:bytea v-author-root)
          (-/field i-commit-root "commit/author-evidence")
          (:bytea v-provenance-root)
          (-/optional-field
           i-commit-root "commit/execution-provenance")
          (:integer v-parent-count)
          (cell/cell-ref-count v-parent-vector-root "element")
          o-insert
          (pg/t:insert
           -/WorkspaceCommit
           {:commit-root i-commit-root
            :workspace-id-root v-workspace-id-root
            :workspace-root v-workspace-root
            :state-root v-state-root
            :operation-root v-operation-root
            :merge-base-root v-merge-base-root
            :merge-policy-root v-merge-policy-root
            :author-evidence-root v-author-root
            :execution-provenance-root v-provenance-root
            :parent-count v-parent-count})
          _ (-/workspace-commit-parent-import-at
             i-commit-root v-parent-vector-root 0 v-parent-count)]
      (return i-commit-root))))

(defn.pg ^{:- [:boolean]}
  workspace-commit-parent-import-at
  {:added "0.11"}
  [:bytea i-commit-root
   :bytea i-parent-vector-root
   :integer i-position
   :integer i-count]
  (cond (>= i-position i-count)
        (return true)

        :else
        (let [(:bytea v-parent-root)
              (cell/cell-ref-child
               i-parent-vector-root i-position "element")
              o-insert
              (pg/t:insert
               -/WorkspaceCommitParent
               {:commit-root i-commit-root
                :position i-position
                :parent-root v-parent-root})]
          (return
           (-/workspace-commit-parent-import-at
            i-commit-root i-parent-vector-root
            (+ i-position 1) i-count)))))

(defn.pg ^{:- [:bytea]}
  workspace-commit-put
  "Constructs and imports one canonical workspace commit candidate."
  {:added "0.11"}
  [:bytea i-workspace-id-root
   :bytea i-workspace-root
   :bytea i-parent-roots-root
   :bytea i-state-root
   :bytea i-operation-root
   :bytea i-merge-base-root
   :bytea i-merge-policy-root
   :bytea i-author-evidence-root
   :bytea i-execution-provenance-root
   :bytea i-metadata-root
   :bytea i-extensions-root]
  (let [(:bytea v-root)
        (-/workspace-commit-value
         i-workspace-id-root i-workspace-root
         i-parent-roots-root i-state-root i-operation-root
         i-merge-base-root i-merge-policy-root
         i-author-evidence-root i-execution-provenance-root
         i-metadata-root i-extensions-root)]
    (return (-/workspace-commit-import v-root))))
