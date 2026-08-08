(ns gwdb.ledger.workflow-projection-test
  (:use code.test)
  (:require [tahto.core :as l]
            [postgres.core :as pg]
            [gwdb.ledger.base :as base]
            [gwdb.ledger.value :as value]
            [gwdb.ledger.workspace :as workspace]
            [gwdb.ledger.workflow-projection :as projection]))

(l/script- :postgres
  {:runtime :jdbc.client
   :config {:dbname "gw-ledger-test"
            :temp :create
            :container {:group "gw-ledger"
                        :image "gw-ledger-postgres:15-pgsodium"
                        :ports [5432]
                        :environment {"POSTGRES_PASSWORD" "postgres"
                                      "POSTGRES_USER" "postgres"
                                      "POSTGRES_HOST_AUTH_METHOD" "md5"
                                      "IGNATIUS_PGSODIUM_ROOT_KEY"
                                      "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"}
                        :cmd ["postgres" "-c" "password_encryption=md5"]}}
   :require [[postgres.core :as pg]
             [gwdb.ledger.base :as base :primary true]
             [gwdb.ledger.value :as value]
             [gwdb.ledger.workspace :as workspace]
             [gwdb.ledger.workflow-projection :as projection]]
   :static {:application ["gw"]
            :seed ["gw_ledger"]
            :all {:schema ["gw_ledger"]}}})

(fact:global
 {:setup [(l/rt:teardown :postgres)
          (l/rt:setup :postgres)]
  :teardown [(l/rt:teardown :postgres)
             (l/rt:stop)]})

(defn.pg ^{:- [:bytea]}
  empty-map
  {:added "0.12"}
  []
  (return (value/put-map (pg/jsonb-build-array))))

(defn.pg ^{:- [:bytea]}
  empty-vector
  {:added "0.12"}
  []
  (return (value/put-vector (pg/jsonb-build-array))))

(defn.pg ^{:- [:bytea]}
  vector-one
  {:added "0.12"}
  [:bytea i-root]
  (return
   (value/put-vector
    (pg/jsonb-build-array (pg/encode i-root "hex")))))

(defn.pg ^{:- [:bytea]}
  base-record
  {:added "0.12"}
  [:text i-kind]
  (let [(:bytea v-record) (workspace/record-start i-kind)
        (:bytea v-version)
        (workspace/record-assoc
         v-record "record/version" (value/put-integer-number 1))]
    (return
     (workspace/record-assoc
      v-version "record/extensions" (-/empty-map)))))

(defn.pg ^{:- [:bytea]}
  evidence
  {:added "0.12"}
  [:bytea i-signer-root :bigint i-timestamp]
  (let [(:bytea v-record) (-/base-record "ledger/evidence")
        (:bytea v-signer)
        (workspace/record-assoc
         v-record "ledger/signer" i-signer-root)
        (:bytea v-transaction)
        (workspace/record-assoc
         v-signer "ledger/transaction-root" (value/put-nil))
        (:bytea v-timestamp)
        (workspace/record-assoc
         v-transaction "ledger/timestamp"
         (value/put-integer-number i-timestamp))
        (:bytea v-head)
        (workspace/record-assoc
         v-timestamp "ledger/previous-head-root" (value/put-nil))
        (:bytea v-contract)
        (workspace/record-assoc
         v-head "ledger/contract-root" (value/put-nil))
        (:bytea v-template)
        (workspace/record-assoc
         v-contract "ledger/template-root" (value/put-nil))]
    (return
     (workspace/record-assoc
      v-template "ledger/global-state-root" (value/put-nil)))))

(defn.pg ^{:- [:bytea]}
  logical-reference
  {:added "0.12"}
  [:bytea i-workspace-id-root
   :bytea i-resource-id-root
   :bytea i-version-root]
  (let [(:bytea v-record) (-/base-record "reference/logical")
        (:bytea v-scope)
        (workspace/record-assoc
         v-record "reference/scope-id" i-workspace-id-root)
        (:bytea v-kind)
        (workspace/record-assoc
         v-scope "reference/kind"
         (value/put-keyword "resource/version"))
        (:bytea v-id)
        (workspace/record-assoc
         v-kind "reference/id" i-resource-id-root)
        (:bytea v-root)
        (workspace/record-assoc
         v-id "reference/root" i-version-root)]
    (return
     (workspace/record-assoc
      v-root "reference/metadata" (-/empty-map)))))

(defn.pg ^{:- [:bytea]}
  work-extensions
  {:added "0.12"}
  [:text i-title
   :text i-kind
   :bytea i-dependencies-root
   :bytea i-inputs-root
   :bytea i-outputs-root
   :bytea i-assignee-root
   :bytea i-created-evidence-root
   :bytea i-claim-evidence-root]
  (let [(:bytea v-map) (-/empty-map)
        (:bytea v-item)
        (workspace/record-assoc
         v-map "work/item" (value/put-boolean true))
        (:bytea v-title)
        (workspace/record-assoc
         v-item "work/title" (value/put-string i-title))
        (:bytea v-kind)
        (workspace/record-assoc
         v-title "work/kind" (value/put-keyword i-kind))
        (:bytea v-dependencies)
        (workspace/record-assoc
         v-kind "work/dependency-ids" i-dependencies-root)
        (:bytea v-inputs)
        (workspace/record-assoc
         v-dependencies "work/input-references" i-inputs-root)
        (:bytea v-outputs)
        (workspace/record-assoc
         v-inputs "work/output-references" i-outputs-root)
        (:bytea v-assignee)
        (workspace/record-assoc
         v-outputs "work/assignee"
         (workspace/optional-root i-assignee-root))
        (:bytea v-created)
        (workspace/record-assoc
         v-assignee "work/created-evidence"
         (workspace/optional-root i-created-evidence-root))]
    (return
     (workspace/record-assoc
      v-created "work/claim-evidence"
      (workspace/optional-root i-claim-evidence-root)))))

(defn.pg ^{:- [:bytea]}
  work-run
  {:added "0.12"}
  [:bytea i-workspace-id-root
   :bytea i-work-id-root
   :text i-status
   :text i-title
   :bytea i-dependencies-root
   :bytea i-inputs-root
   :bytea i-outputs-root
   :bytea i-assignee-root
   :bytea i-created-evidence-root
   :bytea i-claim-evidence-root
   :bytea i-started-evidence-root
   :bytea i-completed-evidence-root]
  (let [(:bytea v-record) (-/base-record "process/run")
        (:bytea v-extensions)
        (-/work-extensions
         i-title "code/change"
         i-dependencies-root i-inputs-root i-outputs-root
         i-assignee-root i-created-evidence-root i-claim-evidence-root)
        (:bytea v-with-extensions)
        (workspace/record-assoc
         v-record "record/extensions" v-extensions)
        (:bytea v-id)
        (workspace/record-assoc
         v-with-extensions "run/id" i-work-id-root)
        (:bytea v-workspace)
        (workspace/record-assoc
         v-id "run/workspace-id" i-workspace-id-root)
        (:bytea v-definition)
        (workspace/record-assoc
         v-workspace "run/definition-root"
         (value/put-string (|| "definition/" (-/scalar-text i-work-id-root))))
        (:bytea v-status)
        (workspace/record-assoc
         v-definition "run/status" (value/put-keyword i-status))
        (:bytea v-result)
        (workspace/record-assoc
         v-status "run/result-root"
         (pg/case (== i-status "complete")
                  (value/put-string (|| "result/" (-/scalar-text i-work-id-root)))
                  :else (value/put-nil)))
        (:bytea v-receipt)
        (workspace/record-assoc
         v-result "run/receipt-root"
         (pg/case (== i-status "complete")
                  (value/put-string (|| "receipt/" (-/scalar-text i-work-id-root)))
                  :else (value/put-nil)))
        (:bytea v-started)
        (workspace/record-assoc
         v-receipt "run/started-evidence"
         (workspace/optional-root i-started-evidence-root))]
    (return
     (workspace/record-assoc
      v-started "run/completed-evidence"
      (workspace/optional-root i-completed-evidence-root)))))

(defn.pg ^{:- [:bytea]}
  resource-version
  {:added "0.12"}
  [:bytea i-resource-id-root
   :bytea i-version-root
   :bytea i-producer-work-id-root
   :bytea i-evidence-root]
  (let [(:bytea v-record) (-/base-record "artifact/version")
        (:bytea v-extension-map) (-/empty-map)
        (:bytea v-provider)
        (workspace/record-assoc
         v-extension-map "resource/provider" (value/put-keyword "git"))
        (:bytea v-locator)
        (workspace/record-assoc
         v-provider "resource/locator" (-/empty-map))
        (:bytea v-digest-algorithm)
        (workspace/record-assoc
         v-locator "resource/digest-algorithm"
         (value/put-keyword "git/sha1"))
        (:bytea v-digest)
        (workspace/record-assoc
         v-digest-algorithm "resource/digest" i-version-root)
        (:bytea v-size)
        (workspace/record-assoc
         v-digest "resource/size" (value/put-integer-number 42))
        (:bytea v-extensions)
        (workspace/record-assoc
         v-record "record/extensions" v-size)
        (:bytea v-id)
        (workspace/record-assoc
         v-extensions "artifact/id" i-resource-id-root)
        (:bytea v-kind)
        (workspace/record-assoc
         v-id "artifact/kind" (value/put-keyword "git/commit"))
        (:bytea v-content)
        (workspace/record-assoc
         v-kind "artifact/content-root" i-version-root)
        (:bytea v-previous)
        (workspace/record-assoc
         v-content "artifact/previous-content-root" (value/put-nil))
        (:bytea v-producer)
        (workspace/record-assoc
         v-previous "artifact/producer-run-id" i-producer-work-id-root)]
    (return
     (workspace/record-assoc
      v-producer "artifact/published-evidence" i-evidence-root))))

(defn.pg ^{:- [:bytea]}
  checkpoint
  {:added "0.12"}
  [:bytea i-checkpoint-id-root
   :bytea i-work-id-root
   :bytea i-evidence-root]
  (let [(:bytea v-record) (-/base-record "process/checkpoint")
        (:bytea v-id)
        (workspace/record-assoc
         v-record "checkpoint/id" i-checkpoint-id-root)
        (:bytea v-run)
        (workspace/record-assoc
         v-id "checkpoint/run-id" i-work-id-root)
        (:bytea v-state)
        (workspace/record-assoc
         v-run "checkpoint/state-root" (value/put-string "state/e/1"))
        (:bytea v-receipt)
        (workspace/record-assoc
         v-state "checkpoint/receipt-root"
         (value/put-string "receipt/checkpoint/e/1"))]
    (return
     (workspace/record-assoc
      v-receipt "checkpoint/evidence" i-evidence-root))))

(defn.pg ^{:- [:bytea]}
  demo-workspace-state
  {:added "0.12"}
  []
  (let [(:bytea v-workspace-id) (value/put-string "greenways/ignatius")
        (:bytea v-alice) (value/put-string "alice")
        (:bytea v-bob) (value/put-string "bob")
        (:bytea v-created-a) (-/evidence v-alice 1)
        (:bytea v-completed-a) (-/evidence v-alice 4)
        (:bytea v-claimed-d) (-/evidence v-bob 5)
        (:bytea v-started-e) (-/evidence v-alice 6)
        (:bytea v-checkpoint-evidence) (-/evidence v-alice 7)
        (:bytea v-work-a-id) (value/put-string "work/a")
        (:bytea v-work-b-id) (value/put-string "work/b")
        (:bytea v-work-c-id) (value/put-string "work/c")
        (:bytea v-work-d-id) (value/put-string "work/d")
        (:bytea v-work-e-id) (value/put-string "work/e")
        (:bytea v-resource-id) (value/put-string "git/demo/agent/a")
        (:bytea v-resource-version) (value/put-string "commit-B")
        (:bytea v-reference)
        (-/logical-reference
         v-workspace-id v-resource-id v-resource-version)
        (:bytea v-reference-vector) (-/vector-one v-reference)
        (:bytea v-work-a)
        (-/work-run
         v-workspace-id v-work-a-id "complete" "Implement A"
         (-/empty-vector) (-/empty-vector) v-reference-vector
         v-alice v-created-a v-created-a v-created-a v-completed-a)
        (:bytea v-work-b)
        (-/work-run
         v-workspace-id v-work-b-id "open" "Implement B"
         (-/vector-one v-work-a-id) v-reference-vector (-/empty-vector)
         nil (-/evidence v-bob 2) nil nil nil)
        (:bytea v-work-c)
        (-/work-run
         v-workspace-id v-work-c-id "open" "Implement C"
         (-/vector-one v-work-b-id) (-/empty-vector) (-/empty-vector)
         nil (-/evidence v-alice 3) nil nil nil)
        (:bytea v-work-d)
        (-/work-run
         v-workspace-id v-work-d-id "claimed" "Implement D"
         (-/empty-vector) (-/empty-vector) (-/empty-vector)
         v-bob (-/evidence v-bob 5) v-claimed-d nil nil)
        (:bytea v-work-e)
        (-/work-run
         v-workspace-id v-work-e-id "running" "Implement E"
         (-/empty-vector) (-/empty-vector) (-/empty-vector)
         v-alice (-/evidence v-alice 6) (-/evidence v-alice 6)
         v-started-e nil)
        (:bytea v-processes-0) (-/empty-map)
        (:bytea v-processes-1)
        (value/map-assoc v-processes-0 v-work-a-id v-work-a)
        (:bytea v-processes-2)
        (value/map-assoc v-processes-1 v-work-b-id v-work-b)
        (:bytea v-processes-3)
        (value/map-assoc v-processes-2 v-work-c-id v-work-c)
        (:bytea v-processes-4)
        (value/map-assoc v-processes-3 v-work-d-id v-work-d)
        (:bytea v-processes)
        (value/map-assoc v-processes-4 v-work-e-id v-work-e)
        (:bytea v-artifact)
        (-/resource-version
         v-resource-id v-resource-version v-work-a-id v-completed-a)
        (:bytea v-current-resources)
        (value/map-assoc (-/empty-map) v-resource-id v-artifact)
        (:bytea v-one-version-map)
        (value/map-assoc (-/empty-map) v-resource-version v-artifact)
        (:bytea v-resource-versions)
        (value/map-assoc
         (-/empty-map) v-resource-id v-one-version-map)
        (:bytea v-checkpoint-id)
        (value/put-string "checkpoint/e/1")
        (:bytea v-checkpoint)
        (-/checkpoint v-checkpoint-id v-work-e-id v-checkpoint-evidence)
        (:bytea v-checkpoints)
        (value/map-assoc (-/empty-map) v-checkpoint-id v-checkpoint)
        (:bytea v-record) (-/base-record "workspace/build")
        (:bytea v-id)
        (workspace/record-assoc
         v-record "workspace/id" v-workspace-id)
        (:bytea v-kind)
        (workspace/record-assoc
         v-id "workspace/kind" (value/put-keyword "agent/workflow"))
        (:bytea v-process-map)
        (workspace/record-assoc
         v-kind "workspace/processes" v-processes)
        (:bytea v-current)
        (workspace/record-assoc
         v-process-map "workspace/artifacts" v-current-resources)
        (:bytea v-versions)
        (workspace/record-assoc
         v-current "workspace/artifact-versions" v-resource-versions)
        (:bytea v-checkpoint-map)
        (workspace/record-assoc
         v-versions "workspace/checkpoints" v-checkpoints)]
    (return
     (workspace/record-assoc
      v-checkpoint-map "workspace/latest-entry-id"
      (value/put-string "tx-checkpoint-e")))))

(defn.pg ^{:- [:jsonb]}
  run-workflow-projection-demo
  {:added "0.12"}
  []
  (let [(:bytea v-state-root) (-/demo-workspace-state)
        (:bytea v-workspace-id-root)
        (workspace/field v-state-root "workspace/id")
        (:bytea v-work-a-id) (value/put-string "work/a")
        (:bytea v-work-c-id) (value/put-string "work/c")
        (:bytea v-work-e-id) (value/put-string "work/e")
        (:bytea v-bob) (value/put-string "bob")
        (:jsonb v-rebuild)
        (projection/workflow-projection-rebuild v-state-root)
        (:jsonb v-ready)
        (projection/workflow-ready-work v-workspace-id-root)
        (:jsonb v-blocked)
        (projection/workflow-blocked-work v-workspace-id-root)
        (:jsonb v-running)
        (projection/workflow-running-work v-workspace-id-root)
        (:jsonb v-bob-work)
        (projection/workflow-work-for-assignee
         v-workspace-id-root v-bob)
        (:jsonb v-blockers)
        (projection/workflow-blocking-dependencies
         v-workspace-id-root v-work-c-id)
        (:jsonb v-checkpoint)
        (projection/workflow-latest-checkpoint
         v-workspace-id-root v-work-e-id)
        (:jsonb v-resources)
        (projection/workflow-resources-for-work
         v-workspace-id-root v-work-a-id)
        (:boolean v-valid)
        (projection/workflow-projection-valid v-state-root)
        _ (pg/t:delete
           projection/WorkflowDependency
           {:where {:workspace-id-root v-workspace-id-root
                    :work-id-root v-work-c-id}})
        (:boolean v-invalid-after-delete)
        (projection/workflow-projection-valid v-state-root)
        (:jsonb v-rebuilt-again)
        (projection/workflow-projection-rebuild v-state-root)
        (:boolean v-valid-after-rebuild)
        (projection/workflow-projection-valid v-state-root)]
    (return
     (pg/jsonb-build-object
      "work_count" (:->> v-rebuild "work_count")
      "dependency_count" (:->> v-rebuild "dependency_count")
      "reference_count" (:->> v-rebuild "reference_count")
      "resource_version_count" (:->> v-rebuild "resource_version_count")
      "checkpoint_count" (:->> v-rebuild "checkpoint_count")
      "ready_id" (:->> (:-> v-ready 0) "work_id")
      "blocked_id" (:->> (:-> v-blocked 0) "work_id")
      "running_id" (:->> (:-> v-running 0) "work_id")
      "bob_work_id" (:->> (:-> v-bob-work 0) "work_id")
      "blocking_dependency_id"
      (:->> (:-> v-blockers 0) "dependency_id")
      "checkpoint_id" (:->> v-checkpoint "checkpoint_id")
      "checkpoint_timestamp" (:->> v-checkpoint "ledger_timestamp")
      "resource_id" (:->> (:-> v-resources 0) "resource_id")
      "resource_version"
      (:->> (:-> v-resources 0) "resource_version")
      "resource_current" (:->> (:-> v-resources 0) "current")
      "valid" v-valid
      "invalid_after_delete" v-invalid-after-delete
      "valid_after_rebuild" v-valid-after-rebuild
      "idempotent_state_root"
      (== (:bytea (:->> v-rebuilt-again "state_root")) v-state-root)))))

^{:refer gwdb.ledger.workflow-projection/workflow-projection-rebuild
  :added "0.12"}
(fact "PostgreSQL rebuilds and queries collaborative workflow projections"
  (!.pg
   [:select (:->> (-/run-workflow-projection-demo) "work_count")]
   [:select (:->> (-/run-workflow-projection-demo) "dependency_count")]
   [:select (:->> (-/run-workflow-projection-demo) "reference_count")]
   [:select (:->> (-/run-workflow-projection-demo) "resource_version_count")]
   [:select (:->> (-/run-workflow-projection-demo) "checkpoint_count")]
   [:select (:->> (-/run-workflow-projection-demo) "ready_id")]
   [:select (:->> (-/run-workflow-projection-demo) "blocked_id")]
   [:select (:->> (-/run-workflow-projection-demo) "running_id")]
   [:select (:->> (-/run-workflow-projection-demo) "bob_work_id")]
   [:select (:->> (-/run-workflow-projection-demo) "blocking_dependency_id")]
   [:select (:->> (-/run-workflow-projection-demo) "checkpoint_id")]
   [:select (:->> (-/run-workflow-projection-demo) "checkpoint_timestamp")]
   [:select (:->> (-/run-workflow-projection-demo) "resource_id")]
   [:select (:->> (-/run-workflow-projection-demo) "resource_version")]
   [:select (:->> (-/run-workflow-projection-demo) "resource_current")]
   [:select (:->> (-/run-workflow-projection-demo) "valid")]
   [:select (:->> (-/run-workflow-projection-demo) "invalid_after_delete")]
   [:select (:->> (-/run-workflow-projection-demo) "valid_after_rebuild")]
   [:select (:->> (-/run-workflow-projection-demo) "idempotent_state_root")])
  => '(5 2 2 1 1
       "work/b" "work/c" "work/e" "work/d" "work/b"
       "checkpoint/e/1" "7"
       "git/demo/agent/a" "commit-B" "true"
       "true" "false" "true" "true"))
