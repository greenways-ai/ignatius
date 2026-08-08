(ns gwdb.ledger.workflow-projection
  (:require [tahto.core :as l]
            [postgres.core :as pg]
            [gwdb.ledger.cell :as cell]
            [gwdb.ledger.codec :as codec]
            [gwdb.ledger.value :as value]
            [gwdb.ledger.workspace :as workspace]))

(l/script :postgres
  {:require [[postgres.core :as pg]
             [gwdb.ledger.cell :as cell]
             [gwdb.ledger.codec :as codec]
             [gwdb.ledger.value :as value]
             [gwdb.ledger.workspace :as workspace]]
   :config {:dbname "gw-ledger-test"}
   :static {:application ["gw"]
            :all {:schema ["gw_ledger"]}}})

(deftype.pg WorkflowProjection
  "Rebuild cursor for one canonical collaborative-work workspace state."
  {:added "0.12"}
  [:workspace-id-root      {:type :bytea :primary true}
   :workspace-id           {:type :text :required true}
   :state-root             {:type :bytea :required true}
   :latest-entry-id-root   {:type :bytea}
   :work-count             {:type :integer :required true}
   :dependency-count       {:type :integer :required true}
   :reference-count        {:type :integer :required true}
   :resource-version-count {:type :integer :required true}
   :checkpoint-count       {:type :integer :required true}])

(deftype.pg WorkflowWork
  "Disposable scheduler projection of one canonical :process/run work item."
  {:added "0.12"}
  [:workspace-id-root            {:type :bytea :primary true}
   :work-id-root                 {:type :bytea :primary true}
   :work-id                      {:type :text :required true}
   :run-root                     {:type :bytea :required true}
   :definition-root              {:type :bytea :required true}
   :title                        {:type :text}
   :kind                         {:type :text}
   :status                       {:type :text :required true}
   :classification               {:type :text :required true}
   :assignee-root                {:type :bytea}
   :assignee                     {:type :text}
   :dependency-count             {:type :integer :required true}
   :unresolved-dependency-count  {:type :integer :required true}
   :input-count                  {:type :integer :required true}
   :output-count                 {:type :integer :required true}
   :result-root                  {:type :bytea}
   :receipt-root                 {:type :bytea}
   :created-evidence-root        {:type :bytea}
   :claim-evidence-root          {:type :bytea}
   :started-evidence-root        {:type :bytea}
   :completed-evidence-root      {:type :bytea}
   :latest-checkpoint-root       {:type :bytea}
   :latest-checkpoint-id         {:type :text}
   :latest-checkpoint-timestamp  {:type :bigint}
   :source-state-root            {:type :bytea :required true}])

(deftype.pg WorkflowDependency
  "Ordered dependency edge derived from a work item."
  {:added "0.12"}
  [:workspace-id-root  {:type :bytea :primary true}
   :work-id-root       {:type :bytea :primary true}
   :position           {:type :integer :primary true}
   :dependency-id-root {:type :bytea :required true}
   :dependency-id      {:type :text :required true}
   :dependency-run-root {:type :bytea}
   :dependency-status  {:type :text}
   :complete           {:type :boolean :required true}
   :source-state-root  {:type :bytea :required true}])

(deftype.pg WorkflowReference
  "Exact input or output resource reference for one work item."
  {:added "0.12"}
  [:workspace-id-root   {:type :bytea :primary true}
   :work-id-root        {:type :bytea :primary true}
   :direction           {:type :text :primary true}
   :position            {:type :integer :primary true}
   :reference-root      {:type :bytea :required true}
   :resource-id-root    {:type :bytea :required true}
   :resource-id         {:type :text :required true}
   :resource-version-root {:type :bytea :required true}
   :resource-version    {:type :text :required true}
   :source-state-root   {:type :bytea :required true}])

(deftype.pg WorkflowResourceVersion
  "Exact external resource version derived from :artifact/version."
  {:added "0.12"}
  [:workspace-id-root       {:type :bytea :primary true}
   :resource-id-root        {:type :bytea :primary true}
   :resource-version-root   {:type :bytea :primary true}
   :resource-id             {:type :text :required true}
   :resource-version        {:type :text :required true}
   :artifact-root           {:type :bytea :required true}
   :current                 {:type :boolean :required true}
   :kind                    {:type :text}
   :provider                {:type :text}
   :previous-version-root   {:type :bytea}
   :previous-version        {:type :text}
   :producer-work-id-root   {:type :bytea}
   :producer-work-id        {:type :text}
   :locator-root            {:type :bytea}
   :digest-algorithm        {:type :text}
   :digest                  {:type :text}
   :size                    {:type :bigint}
   :published-evidence-root {:type :bytea}
   :source-state-root       {:type :bytea :required true}])

(deftype.pg WorkflowCheckpoint
  "Checkpoint projection with verified ledger time for deterministic recovery."
  {:added "0.12"}
  [:workspace-id-root {:type :bytea :primary true}
   :checkpoint-id-root {:type :bytea :primary true}
   :checkpoint-id      {:type :text :required true}
   :checkpoint-root    {:type :bytea :required true}
   :work-id-root       {:type :bytea :required true}
   :work-id            {:type :text :required true}
   :state-root         {:type :bytea :required true}
   :receipt-root       {:type :bytea}
   :evidence-root      {:type :bytea :required true}
   :ledger-timestamp   {:type :bigint :required true}
   :source-state-root  {:type :bytea :required true}])

(defn.pg ^{:- [:bytea]}
  optional-root
  {:added "0.12"}
  [:bytea i-root]
  (cond [i-root :is-null]
        (return nil)

        (== (cell/cell-type-tag i-root) 0)
        (return nil)

        :else
        (return i-root)))

(defn.pg ^{:- [:text]}
  scalar-text
  "Reads an HCV1 string, symbol or keyword as UTF-8 text."
  {:added "0.12"}
  [:bytea i-root]
  (cond [i-root :is-null]
        (return nil)

        :else
        (let [o-cell (cell/cell-by-hash i-root)
              (:smallint v-tag) (:smallint (:->> o-cell "type_tag"))
              _ (pg/assert
                 (and [o-cell :is-not-null]
                      (or (== v-tag 5)
                          (== v-tag 7)
                          (== v-tag 8)))
                 [:ledger/workflow-projection-not-text])]
          (return
           (pg/encode
            (:bytea (:->> o-cell "payload")) "escape")))))

(defn.pg ^{:- [:boolean]}
  scalar-boolean
  {:added "0.12"}
  [:bytea i-root]
  (cond [i-root :is-null]
        (return false)

        :else
        (let [o-cell (cell/cell-by-hash i-root)
              _ (pg/assert
                 (and [o-cell :is-not-null]
                      (== (:smallint (:->> o-cell "type_tag")) 1))
                 [:ledger/workflow-projection-not-boolean])]
          (return
           (== (:bytea (:->> o-cell "payload"))
               (pg/decode "01" "hex"))))))

(defn.pg ^{:- [:bigint]}
  optional-integer
  {:added "0.12"}
  [:bytea i-root]
  (cond [i-root :is-null]
        (return nil)

        (== (cell/cell-type-tag i-root) 0)
        (return nil)

        :else
        (return (value/integer-bigint i-root))))

(defn.pg ^{:- [:bytea]}
  extension-field
  {:added "0.12"}
  [:bytea i-record-root :text i-name]
  (let [(:bytea v-extensions)
        (workspace/field i-record-root "record/extensions")]
    (cond [v-extensions :is-null]
          (return nil)

          :else
          (return (workspace/field v-extensions i-name)))))

(defn.pg ^{:- [:bytea]}
  optional-extension-field
  {:added "0.12"}
  [:bytea i-record-root :text i-name]
  (return
   (-/optional-root
    (-/extension-field i-record-root i-name))))

(defn.pg ^{:- [:integer]}
  map-count
  {:added "0.12"}
  [:bytea i-map-root]
  (cond [i-map-root :is-null]
        (return 0)

        (== (cell/cell-type-tag i-map-root) 0)
        (return 0)

        :else
        (let [_ (pg/assert
                 (== (cell/cell-type-tag i-map-root) 11)
                 [:ledger/workflow-projection-not-map])]
          (return (cell/cell-ref-count i-map-root "key")))))

(defn.pg ^{:- [:integer]}
  vector-count
  {:added "0.12"}
  [:bytea i-vector-root]
  (cond [i-vector-root :is-null]
        (return 0)

        (== (cell/cell-type-tag i-vector-root) 0)
        (return 0)

        :else
        (let [_ (pg/assert
                 (== (cell/cell-type-tag i-vector-root) 10)
                 [:ledger/workflow-projection-not-vector])]
          (return (cell/cell-ref-count i-vector-root "element")))))

(defn.pg ^{:- [:bytea]}
  map-key
  {:added "0.12"}
  [:bytea i-map-root :integer i-position]
  (return
   (cell/cell-ref-child i-map-root i-position "key")))

(defn.pg ^{:- [:bytea]}
  map-value
  {:added "0.12"}
  [:bytea i-map-root :integer i-position]
  (return
   (cell/cell-ref-child i-map-root i-position "value")))

(defn.pg ^{:- [:bytea]}
  vector-value
  {:added "0.12"}
  [:bytea i-vector-root :integer i-position]
  (return
   (cell/cell-ref-child i-vector-root i-position "element")))

(defn.pg ^{:- [:text]}
  work-classification
  {:added "0.12"}
  [:text i-status :integer i-unresolved-count]
  (cond (== i-status "open")
        (return
         (pg/case (== i-unresolved-count 0)
                  "ready"
                  :else "blocked"))

        (== i-status "claimed")
        (return "claimed")

        (== i-status "running")
        (return "running")

        (== i-status "complete")
        (return "complete")

        :else
        (return "unknown")))

(defn.pg ^{:- [:boolean]}
  workflow-work-item
  {:added "0.12"}
  [:bytea i-run-root]
  (return
   (-/scalar-boolean
    (-/extension-field i-run-root "work/item"))))

(defn.pg ^{:- [:boolean]}
  projection-clear
  {:added "0.12"}
  [:bytea i-workspace-id-root]
  (let [_ (pg/t:delete -/WorkflowReference
                        {:where {:workspace-id-root i-workspace-id-root}})
        _ (pg/t:delete -/WorkflowDependency
                        {:where {:workspace-id-root i-workspace-id-root}})
        _ (pg/t:delete -/WorkflowCheckpoint
                        {:where {:workspace-id-root i-workspace-id-root}})
        _ (pg/t:delete -/WorkflowResourceVersion
                        {:where {:workspace-id-root i-workspace-id-root}})
        _ (pg/t:delete -/WorkflowWork
                        {:where {:workspace-id-root i-workspace-id-root}})
        _ (pg/t:delete -/WorkflowProjection
                        {:where {:workspace-id-root i-workspace-id-root}})]
    (return true)))

(defn.pg ^{:- [:integer]}
  import-work-references
  {:added "0.12"}
  [:bytea i-workspace-id-root
   :bytea i-work-id-root
   :text i-direction
   :bytea i-reference-vector-root
   :bytea i-source-state-root]
  (let [(:integer v-count) (-/vector-count i-reference-vector-root)
        (:integer v-position) 0
        (:bytea v-reference-root) nil
        (:bytea v-resource-id-root) nil
        (:bytea v-resource-version-root) nil
        o-row nil]
    (while (< v-position v-count)
      (:= v-reference-root
          (-/vector-value i-reference-vector-root v-position))
      (:= v-resource-id-root
          (workspace/field v-reference-root "reference/id"))
      (:= v-resource-version-root
          (-/optional-root
           (workspace/field v-reference-root "reference/root")))
      (pg/assert [v-resource-id-root :is-not-null]
                 [:ledger/workflow-reference-missing-resource-id])
      (pg/assert [v-resource-version-root :is-not-null]
                 [:ledger/workflow-reference-not-exact])
      (:= o-row
          (pg/t:upsert
           -/WorkflowReference
           {:workspace-id-root i-workspace-id-root
            :work-id-root i-work-id-root
            :direction i-direction
            :position v-position
            :reference-root v-reference-root
            :resource-id-root v-resource-id-root
            :resource-id (-/scalar-text v-resource-id-root)
            :resource-version-root v-resource-version-root
            :resource-version
            (-/scalar-text v-resource-version-root)
            :source-state-root i-source-state-root}))
      (:= v-position (+ v-position 1)))
    (return v-count)))

(defn.pg ^{:- [:jsonb]}
  import-work-items
  {:added "0.12"}
  [:bytea i-workspace-id-root
   :bytea i-process-map-root
   :bytea i-source-state-root]
  (let [(:integer v-process-count) (-/map-count i-process-map-root)
        (:integer v-position) 0
        (:integer v-work-count) 0
        (:integer v-dependency-total) 0
        (:integer v-reference-total) 0
        (:bytea v-work-id-root) nil
        (:bytea v-run-root) nil
        (:bytea v-definition-root) nil
        (:bytea v-status-root) nil
        (:text v-status) nil
        (:bytea v-dependency-vector-root) nil
        (:bytea v-input-vector-root) nil
        (:bytea v-output-vector-root) nil
        (:integer v-dependency-count) 0
        (:integer v-dependency-position) 0
        (:integer v-unresolved-count) 0
        (:bytea v-dependency-id-root) nil
        (:bytea v-dependency-run-root) nil
        (:bytea v-dependency-status-root) nil
        (:text v-dependency-status) nil
        (:boolean v-dependency-complete) false
        (:bytea v-assignee-root) nil
        (:bytea v-title-root) nil
        (:bytea v-kind-root) nil
        o-row nil]
    (while (< v-position v-process-count)
      (:= v-work-id-root
          (-/map-key i-process-map-root v-position))
      (:= v-run-root
          (-/map-value i-process-map-root v-position))
      (when (-/workflow-work-item v-run-root)
        (:= v-definition-root
            (workspace/field v-run-root "run/definition-root"))
        (:= v-status-root
            (workspace/field v-run-root "run/status"))
        (:= v-status (-/scalar-text v-status-root))
        (:= v-dependency-vector-root
            (-/extension-field v-run-root "work/dependency-ids"))
        (:= v-input-vector-root
            (-/extension-field v-run-root "work/input-references"))
        (:= v-output-vector-root
            (-/extension-field v-run-root "work/output-references"))
        (:= v-dependency-count
            (-/vector-count v-dependency-vector-root))
        (:= v-dependency-position 0)
        (:= v-unresolved-count 0)
        (while (< v-dependency-position v-dependency-count)
          (:= v-dependency-id-root
              (-/vector-value
               v-dependency-vector-root v-dependency-position))
          (:= v-dependency-run-root
              (value/map-get
               i-process-map-root v-dependency-id-root))
          (:= v-dependency-status-root
              (pg/case [v-dependency-run-root :is-null]
                       nil
                       :else
                       (workspace/field
                        v-dependency-run-root "run/status")))
          (:= v-dependency-status
              (-/scalar-text v-dependency-status-root))
          (:= v-dependency-complete
              (and [v-dependency-run-root :is-not-null]
                   (== v-dependency-status "complete")))
          (when (not v-dependency-complete)
            (:= v-unresolved-count
                (+ v-unresolved-count 1)))
          (:= o-row
              (pg/t:upsert
               -/WorkflowDependency
               {:workspace-id-root i-workspace-id-root
                :work-id-root v-work-id-root
                :position v-dependency-position
                :dependency-id-root v-dependency-id-root
                :dependency-id (-/scalar-text v-dependency-id-root)
                :dependency-run-root v-dependency-run-root
                :dependency-status v-dependency-status
                :complete v-dependency-complete
                :source-state-root i-source-state-root}))
          (:= v-dependency-position
              (+ v-dependency-position 1)))
        (:= v-assignee-root
            (-/optional-extension-field
             v-run-root "work/assignee"))
        (:= v-title-root
            (-/optional-extension-field v-run-root "work/title"))
        (:= v-kind-root
            (-/optional-extension-field v-run-root "work/kind"))
        (:= o-row
            (pg/t:upsert
             -/WorkflowWork
             {:workspace-id-root i-workspace-id-root
              :work-id-root v-work-id-root
              :work-id (-/scalar-text v-work-id-root)
              :run-root v-run-root
              :definition-root v-definition-root
              :title (-/scalar-text v-title-root)
              :kind (-/scalar-text v-kind-root)
              :status v-status
              :classification
              (-/work-classification v-status v-unresolved-count)
              :assignee-root v-assignee-root
              :assignee (-/scalar-text v-assignee-root)
              :dependency-count v-dependency-count
              :unresolved-dependency-count v-unresolved-count
              :input-count (-/vector-count v-input-vector-root)
              :output-count (-/vector-count v-output-vector-root)
              :result-root
              (-/optional-root
               (workspace/field v-run-root "run/result-root"))
              :receipt-root
              (-/optional-root
               (workspace/field v-run-root "run/receipt-root"))
              :created-evidence-root
              (-/optional-extension-field
               v-run-root "work/created-evidence")
              :claim-evidence-root
              (-/optional-extension-field
               v-run-root "work/claim-evidence")
              :started-evidence-root
              (-/optional-root
               (workspace/field v-run-root "run/started-evidence"))
              :completed-evidence-root
              (-/optional-root
               (workspace/field v-run-root "run/completed-evidence"))
              :latest-checkpoint-root nil
              :latest-checkpoint-id nil
              :latest-checkpoint-timestamp nil
              :source-state-root i-source-state-root}))
        (:= v-reference-total
            (+ v-reference-total
               (-/import-work-references
                i-workspace-id-root v-work-id-root "input"
                v-input-vector-root i-source-state-root)))
        (:= v-reference-total
            (+ v-reference-total
               (-/import-work-references
                i-workspace-id-root v-work-id-root "output"
                v-output-vector-root i-source-state-root)))
        (:= v-dependency-total
            (+ v-dependency-total v-dependency-count))
        (:= v-work-count (+ v-work-count 1)))
      (:= v-position (+ v-position 1)))
    (return
     (pg/jsonb-build-object
      "work_count" v-work-count
      "dependency_count" v-dependency-total
      "reference_count" v-reference-total))))

(defn.pg ^{:- [:integer]}
  import-resource-versions
  {:added "0.12"}
  [:bytea i-workspace-id-root
   :bytea i-current-resource-map-root
   :bytea i-resource-version-map-root
   :bytea i-source-state-root]
  (let [(:integer v-resource-count)
        (-/map-count i-resource-version-map-root)
        (:integer v-resource-position) 0
        (:integer v-version-total) 0
        (:bytea v-resource-id-root) nil
        (:bytea v-version-map-root) nil
        (:integer v-version-count) 0
        (:integer v-version-position) 0
        (:bytea v-version-root) nil
        (:bytea v-artifact-root) nil
        (:bytea v-current-artifact-root) nil
        (:bytea v-current-version-root) nil
        (:bytea v-kind-root) nil
        (:bytea v-provider-root) nil
        (:bytea v-previous-root) nil
        (:bytea v-producer-root) nil
        (:bytea v-locator-root) nil
        (:bytea v-digest-algorithm-root) nil
        (:bytea v-digest-root) nil
        (:bytea v-size-root) nil
        o-row nil]
    (while (< v-resource-position v-resource-count)
      (:= v-resource-id-root
          (-/map-key
           i-resource-version-map-root v-resource-position))
      (:= v-version-map-root
          (-/map-value
           i-resource-version-map-root v-resource-position))
      (:= v-current-artifact-root
          (value/map-get
           i-current-resource-map-root v-resource-id-root))
      (:= v-current-version-root
          (pg/case [v-current-artifact-root :is-null]
                   nil
                   :else
                   (workspace/field
                    v-current-artifact-root
                    "artifact/content-root")))
      (:= v-version-count (-/map-count v-version-map-root))
      (:= v-version-position 0)
      (while (< v-version-position v-version-count)
        (:= v-version-root
            (-/map-key v-version-map-root v-version-position))
        (:= v-artifact-root
            (-/map-value v-version-map-root v-version-position))
        (:= v-kind-root
            (-/optional-root
             (workspace/field v-artifact-root "artifact/kind")))
        (:= v-provider-root
            (-/optional-extension-field
             v-artifact-root "resource/provider"))
        (:= v-previous-root
            (-/optional-root
             (workspace/field
              v-artifact-root "artifact/previous-content-root")))
        (:= v-producer-root
            (-/optional-root
             (workspace/field
              v-artifact-root "artifact/producer-run-id")))
        (:= v-locator-root
            (-/optional-extension-field
             v-artifact-root "resource/locator"))
        (:= v-digest-algorithm-root
            (-/optional-extension-field
             v-artifact-root "resource/digest-algorithm"))
        (:= v-digest-root
            (-/optional-extension-field
             v-artifact-root "resource/digest"))
        (:= v-size-root
            (-/optional-extension-field
             v-artifact-root "resource/size"))
        (:= o-row
            (pg/t:upsert
             -/WorkflowResourceVersion
             {:workspace-id-root i-workspace-id-root
              :resource-id-root v-resource-id-root
              :resource-version-root v-version-root
              :resource-id (-/scalar-text v-resource-id-root)
              :resource-version (-/scalar-text v-version-root)
              :artifact-root v-artifact-root
              :current (== v-current-version-root v-version-root)
              :kind (-/scalar-text v-kind-root)
              :provider (-/scalar-text v-provider-root)
              :previous-version-root v-previous-root
              :previous-version (-/scalar-text v-previous-root)
              :producer-work-id-root v-producer-root
              :producer-work-id (-/scalar-text v-producer-root)
              :locator-root v-locator-root
              :digest-algorithm
              (-/scalar-text v-digest-algorithm-root)
              :digest (-/scalar-text v-digest-root)
              :size (-/optional-integer v-size-root)
              :published-evidence-root
              (-/optional-root
               (workspace/field
                v-artifact-root "artifact/published-evidence"))
              :source-state-root i-source-state-root}))
        (:= v-version-position (+ v-version-position 1))
        (:= v-version-total (+ v-version-total 1)))
      (:= v-resource-position (+ v-resource-position 1)))
    (return v-version-total)))

(defn.pg ^{:- [:boolean]}
  checkpoint-is-later
  {:added "0.12"}
  [:bigint i-candidate-timestamp
   :bytea i-candidate-root
   :bigint i-current-timestamp
   :bytea i-current-root]
  (cond [i-current-root :is-null]
        (return true)

        (> i-candidate-timestamp i-current-timestamp)
        (return true)

        (< i-candidate-timestamp i-current-timestamp)
        (return false)

        :else
        (return (> (codec/compare i-candidate-root i-current-root) 0))))

(defn.pg ^{:- [:integer]}
  import-checkpoints
  {:added "0.12"}
  [:bytea i-workspace-id-root
   :bytea i-checkpoint-map-root
   :bytea i-source-state-root]
  (let [(:integer v-count) (-/map-count i-checkpoint-map-root)
        (:integer v-position) 0
        (:bytea v-checkpoint-id-root) nil
        (:bytea v-checkpoint-root) nil
        (:bytea v-work-id-root) nil
        (:bytea v-state-root) nil
        (:bytea v-receipt-root) nil
        (:bytea v-evidence-root) nil
        (:bytea v-timestamp-root) nil
        (:bigint v-timestamp) nil
        o-work nil
        (:bytea v-current-root) nil
        (:bigint v-current-timestamp) nil
        o-row nil]
    (while (< v-position v-count)
      (:= v-checkpoint-id-root
          (-/map-key i-checkpoint-map-root v-position))
      (:= v-checkpoint-root
          (-/map-value i-checkpoint-map-root v-position))
      (:= v-work-id-root
          (workspace/field v-checkpoint-root "checkpoint/run-id"))
      (:= v-state-root
          (workspace/field v-checkpoint-root "checkpoint/state-root"))
      (:= v-receipt-root
          (-/optional-root
           (workspace/field v-checkpoint-root "checkpoint/receipt-root")))
      (:= v-evidence-root
          (workspace/field v-checkpoint-root "checkpoint/evidence"))
      (:= v-timestamp-root
          (workspace/field v-evidence-root "ledger/timestamp"))
      (:= v-timestamp (value/integer-bigint v-timestamp-root))
      (:= o-row
          (pg/t:upsert
           -/WorkflowCheckpoint
           {:workspace-id-root i-workspace-id-root
            :checkpoint-id-root v-checkpoint-id-root
            :checkpoint-id (-/scalar-text v-checkpoint-id-root)
            :checkpoint-root v-checkpoint-root
            :work-id-root v-work-id-root
            :work-id (-/scalar-text v-work-id-root)
            :state-root v-state-root
            :receipt-root v-receipt-root
            :evidence-root v-evidence-root
            :ledger-timestamp v-timestamp
            :source-state-root i-source-state-root}))
      (:= o-work
          (pg/t:get
           -/WorkflowWork
           {:where {:workspace-id-root i-workspace-id-root
                    :work-id-root v-work-id-root}}))
      (pg/assert [o-work :is-not-null]
                 [:ledger/workflow-checkpoint-work-not-projected])
      (:= v-current-root
          (:bytea (:->> o-work "latest_checkpoint_root")))
      (:= v-current-timestamp
          (:bigint (:->> o-work "latest_checkpoint_timestamp")))
      (when (-/checkpoint-is-later
             v-timestamp v-checkpoint-root
             v-current-timestamp v-current-root)
        (:= o-row
            (pg/t:update!
             -/WorkflowWork
             {:where {:workspace-id-root i-workspace-id-root
                      :work-id-root v-work-id-root}
              :set {:latest-checkpoint-root v-checkpoint-root
                    :latest-checkpoint-id
                    (-/scalar-text v-checkpoint-id-root)
                    :latest-checkpoint-timestamp v-timestamp}})))
      (:= v-position (+ v-position 1)))
    (return v-count)))

(defn.pg ^{:- [:jsonb]}
  workflow-projection-rebuild
  "Drops and deterministically rebuilds one workspace's disposable projections."
  {:added "0.12"}
  [:bytea i-state-root]
  (let [_ (pg/assert
           (workspace/record-kind i-state-root "workspace/build")
           [:ledger/workflow-projection-invalid-workspace])
        _ (pg/assert
           (workspace/record-version-one i-state-root)
           [:ledger/workflow-projection-unsupported-version])
        (:bytea v-workspace-id-root)
        (workspace/field i-state-root "workspace/id")
        (:bytea v-process-map-root)
        (workspace/field i-state-root "workspace/processes")
        (:bytea v-current-resource-map-root)
        (workspace/field i-state-root "workspace/artifacts")
        (:bytea v-resource-version-map-root)
        (workspace/field i-state-root "workspace/artifact-versions")
        (:bytea v-checkpoint-map-root)
        (workspace/field i-state-root "workspace/checkpoints")
        (:bytea v-latest-entry-id-root)
        (-/optional-root
         (workspace/field i-state-root "workspace/latest-entry-id"))
        _ (-/projection-clear v-workspace-id-root)
        (:jsonb v-work-result)
        (-/import-work-items
         v-workspace-id-root v-process-map-root i-state-root)
        (:integer v-work-count)
        (:integer (:->> v-work-result "work_count"))
        (:integer v-dependency-count)
        (:integer (:->> v-work-result "dependency_count"))
        (:integer v-reference-count)
        (:integer (:->> v-work-result "reference_count"))
        (:integer v-resource-version-count)
        (-/import-resource-versions
         v-workspace-id-root
         v-current-resource-map-root
         v-resource-version-map-root
         i-state-root)
        (:integer v-checkpoint-count)
        (-/import-checkpoints
         v-workspace-id-root v-checkpoint-map-root i-state-root)
        o-cursor
        (pg/t:insert
         -/WorkflowProjection
         {:workspace-id-root v-workspace-id-root
          :workspace-id (-/scalar-text v-workspace-id-root)
          :state-root i-state-root
          :latest-entry-id-root v-latest-entry-id-root
          :work-count v-work-count
          :dependency-count v-dependency-count
          :reference-count v-reference-count
          :resource-version-count v-resource-version-count
          :checkpoint-count v-checkpoint-count})]
    (return
     (pg/jsonb-build-object
      "workspace_id" (-/scalar-text v-workspace-id-root)
      "workspace_id_root" v-workspace-id-root
      "state_root" i-state-root
      "latest_entry_id_root" v-latest-entry-id-root
      "work_count" v-work-count
      "dependency_count" v-dependency-count
      "reference_count" v-reference-count
      "resource_version_count" v-resource-version-count
      "checkpoint_count" v-checkpoint-count))))

(defn.pg ^{:- [:boolean]}
  workflow-projection-valid
  "Checks the cursor and row counts against one projected canonical state root."
  {:added "0.12"}
  [:bytea i-state-root]
  (let [(:bytea v-workspace-id-root)
        (workspace/field i-state-root "workspace/id")
        o-cursor
        (pg/t:get
         -/WorkflowProjection
         {:where {:workspace-id-root v-workspace-id-root}})]
    (cond [o-cursor :is-null]
          (return false)

          :else
          (return
           (and
            (== (:bytea (:->> o-cursor "state_root")) i-state-root)
            (== (:integer (:->> o-cursor "work_count"))
                (pg/t:count
                 -/WorkflowWork
                 {:where {:workspace-id-root v-workspace-id-root}}))
            (== (:integer (:->> o-cursor "dependency_count"))
                (pg/t:count
                 -/WorkflowDependency
                 {:where {:workspace-id-root v-workspace-id-root}}))
            (== (:integer (:->> o-cursor "reference_count"))
                (pg/t:count
                 -/WorkflowReference
                 {:where {:workspace-id-root v-workspace-id-root}}))
            (== (:integer (:->> o-cursor "resource_version_count"))
                (pg/t:count
                 -/WorkflowResourceVersion
                 {:where {:workspace-id-root v-workspace-id-root}}))
            (== (:integer (:->> o-cursor "checkpoint_count"))
                (pg/t:count
                 -/WorkflowCheckpoint
                 {:where {:workspace-id-root v-workspace-id-root}})))))))

(defn.pg ^{:- [:jsonb]}
  workflow-work-items
  {:added "0.12"}
  [:bytea i-workspace-id-root :text i-classification]
  (return
   (pg/t:select
    -/WorkflowWork
    {:where {:workspace-id-root i-workspace-id-root
             :classification i-classification}
     :order-by [:work-id]})))

(defn.pg ^{:- [:jsonb]}
  workflow-ready-work
  {:added "0.12"}
  [:bytea i-workspace-id-root]
  (return
   (-/workflow-work-items i-workspace-id-root "ready")))

(defn.pg ^{:- [:jsonb]}
  workflow-blocked-work
  {:added "0.12"}
  [:bytea i-workspace-id-root]
  (return
   (-/workflow-work-items i-workspace-id-root "blocked")))

(defn.pg ^{:- [:jsonb]}
  workflow-running-work
  {:added "0.12"}
  [:bytea i-workspace-id-root]
  (return
   (-/workflow-work-items i-workspace-id-root "running")))

(defn.pg ^{:- [:jsonb]}
  workflow-complete-work
  {:added "0.12"}
  [:bytea i-workspace-id-root]
  (return
   (-/workflow-work-items i-workspace-id-root "complete")))

(defn.pg ^{:- [:jsonb]}
  workflow-work-for-assignee
  {:added "0.12"}
  [:bytea i-workspace-id-root :bytea i-assignee-root]
  (return
   (pg/t:select
    -/WorkflowWork
    {:where {:workspace-id-root i-workspace-id-root
             :assignee-root i-assignee-root}
     :order-by [:work-id]})))

(defn.pg ^{:- [:jsonb]}
  workflow-blocking-dependencies
  {:added "0.12"}
  [:bytea i-workspace-id-root :bytea i-work-id-root]
  (return
   (pg/t:select
    -/WorkflowDependency
    {:where {:workspace-id-root i-workspace-id-root
             :work-id-root i-work-id-root
             :complete false}
     :order-by [:position]})))

(defn.pg ^{:- [:jsonb]}
  workflow-latest-checkpoint
  {:added "0.12"}
  [:bytea i-workspace-id-root :bytea i-work-id-root]
  (let [o-work
        (pg/t:get
         -/WorkflowWork
         {:where {:workspace-id-root i-workspace-id-root
                  :work-id-root i-work-id-root}})
        (:bytea v-checkpoint-root)
        (:bytea (:->> o-work "latest_checkpoint_root"))]
    (cond (or [o-work :is-null]
              [v-checkpoint-root :is-null])
          (return nil)

          :else
          (return
           (pg/t:get
            -/WorkflowCheckpoint
            {:where {:workspace-id-root i-workspace-id-root
                     :checkpoint-root v-checkpoint-root}})))))

(defn.pg ^{:- [:jsonb]}
  workflow-resources-for-work
  {:added "0.12"}
  [:bytea i-workspace-id-root :bytea i-work-id-root]
  (return
   (pg/t:select
    -/WorkflowResourceVersion
    {:where {:workspace-id-root i-workspace-id-root
             :producer-work-id-root i-work-id-root}
     :order-by [:resource-id :resource-version]})))
