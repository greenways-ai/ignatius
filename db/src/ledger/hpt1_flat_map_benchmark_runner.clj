(ns ledger.hpt1-flat-map-benchmark-runner
  (:require [clojure.java.io :as io]
            [ledger.hpt1-flat-map-benchmark :as benchmark]
            [tahto.core :as l]
            [postgres.core :as pg]
            [gwdb.ledger.cell :as cell]
            [gwdb.ledger.value :as value])
  (:import [java.nio.file
            AtomicMoveNotSupportedException
            CopyOption
            Files
            StandardCopyOption]
           [java.nio.file.attribute FileAttribute]))

(l/script- :postgres
  {:runtime :jdbc.client
   :config {:dbname "gw-ledger-test"
            :temp :create
            :vendor :impossibl
            :container {:group "gw-ledger"
                        :image "gw-ledger-postgres:15-pgsodium"
                        :ports [5432]
                        :environment
                        {"POSTGRES_PASSWORD" "postgres"
                         "POSTGRES_USER" "postgres"
                         "POSTGRES_HOST_AUTH_METHOD" "md5"
                         "IGNATIUS_PGSODIUM_ROOT_KEY"
                         "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"}
                        :cmd ["postgres"
                              "-c" "password_encryption=md5"]}}
   :require [[postgres.core :as pg]
             [gwdb.ledger.cell :as cell]
             [gwdb.ledger.value :as value :primary true]]
   :static {:application ["gw"]
            :seed ["gw_ledger"]
            :all {:schema ["gw_ledger"]}}})

(defn.pg ^{:- [:bytea]}
  benchmark-put-map
  "Builds a map from a JSON text array of canonical key/value root hex."
  {:added "0.18"}
  [:text i-root-pairs-json]
  (return
   (value/put-map (:jsonb i-root-pairs-json))))

(defn.pg ^{:- [:jsonb]}
  benchmark-map-shape
  "Returns the stored payload bytes and derived key/value reference counts."
  {:added "0.18"}
  [:bytea i-map-root]
  (let [o-cell (cell/cell-by-hash i-map-root)
        _ (pg/assert [o-cell :is-not-null]
                     [:ledger/missing-benchmark-map])]
    (return
     (pg/jsonb-build-object
      "payload_bytes" (:integer (:->> o-cell "byte_size"))
      "key_refs" (cell/cell-ref-count i-map-root "key")
      "value_refs" (cell/cell-ref-count i-map-root "value")))))

(def benchmark-namespace
  'ledger.hpt1-flat-map-benchmark-runner)

(def benchmark-module
  'ledger.hpt1-flat-map-benchmark-runner)

(def teardown-timeout-ms 10000)

(def measured-sample-paths
  [[:get :first]
   [:get :middle]
   [:get :last]
   [:get :missing-before]
   [:get :missing-after]
   [:assoc-existing :first]
   [:assoc-existing :middle]
   [:assoc-existing :last]
   [:assoc-new :append]
   [:assoc-new :interior]])

(defn validate-evidence!
  "Fails before publication unless every requested case and timing sample exists."
  [evidence entry-counts sample-count]
  (let [results (:results evidence)
        actual-counts (mapv :entry-count results)]
    (when-not (= :hcv1-flat-map-jdbc-baseline
                 (:evidence/kind evidence))
      (throw
       (ex-info
        "unexpected benchmark evidence kind"
        {:expected :hcv1-flat-map-jdbc-baseline
         :observed (:evidence/kind evidence)})))
    (when-not (= entry-counts actual-counts)
      (throw
       (ex-info
        "benchmark evidence does not contain the requested entry counts"
        {:expected entry-counts
         :observed actual-counts})))
    (doseq [result results]
      (when-not (= :ok (:status result))
        (throw
         (ex-info
          "benchmark entry-count case failed"
          {:entry-count (:entry-count result)
           :result result})))
      (doseq [path measured-sample-paths]
        (let [summary (get-in result path)]
          (when-not (= sample-count (:sample-count summary))
            (throw
             (ex-info
              "benchmark summary has the wrong sample count"
              {:entry-count (:entry-count result)
               :path path
               :expected sample-count
               :observed (:sample-count summary)})))
          (when-not (= sample-count (count (:samples-ns summary)))
            (throw
             (ex-info
              "benchmark summary is missing raw samples"
              {:entry-count (:entry-count result)
               :path path
               :expected sample-count
               :observed (count (:samples-ns summary))}))))))
    evidence))

(defn atomic-move!
  [source target]
  (try
    (Files/move
     source target
     (into-array
      CopyOption
      [StandardCopyOption/ATOMIC_MOVE
       StandardCopyOption/REPLACE_EXISTING]))
    (catch AtomicMoveNotSupportedException _
      (Files/move
       source target
       (into-array
        CopyOption
        [StandardCopyOption/REPLACE_EXISTING])))))

(defn write-evidence-atomically!
  "Writes and validates a complete file before replacing the public evidence path."
  [path evidence]
  (let [target-file (.getAbsoluteFile (io/file path))
        _ (io/make-parents target-file)
        target (.toPath target-file)
        parent (.getParent target)
        temporary
        (Files/createTempFile
         parent
         (str "." (.getName target-file) ".")
         ".tmp"
         (make-array FileAttribute 0))]
    (try
      (benchmark/write-evidence! (.toString temporary) evidence)
      (atomic-move! temporary target)
      (.getPath target-file)
      (finally
        (Files/deleteIfExists temporary)))))

(defn bounded-teardown!
  "Attempts normal runtime cleanup without allowing a lingering JDBC thread to
  keep the evidence process alive indefinitely. The worker is daemonised so the
  explicit JVM exit remains authoritative after the timeout."
  [runtime module]
  (let [failure (atom nil)
        worker
        (doto
         (Thread.
          (fn []
            (binding [*ns* (the-ns benchmark-namespace)]
              (try
                (l/rt:teardown runtime module)
                (catch Throwable error
                  (reset! failure error)))))
          "hpt1-flat-map-benchmark-teardown")
          (.setDaemon true)
          (.start))]
    (.join worker teardown-timeout-ms)
    (cond
      (.isAlive worker)
      (do
        (.interrupt worker)
        (binding [*out* *err*]
          (println
           "PostgreSQL benchmark cleanup warning: teardown exceeded"
           teardown-timeout-ms
           "milliseconds; the workflow container trap will remove leftovers."))
        false)

      @failure
      (do
        (binding [*out* *err*]
          (println "PostgreSQL benchmark cleanup warning:"
                   (.getMessage ^Throwable @failure)))
        false)

      :else
      true)))

(defn run-benchmark!
  [output-path]
  ;; The normal ledger primary module is an aggregate root that installs every
  ;; protocol function. This runner owns a minimal SQL module so the flat-map
  ;; evidence depends only on the real cell/value implementation and its closure.
  (binding [*ns* (the-ns benchmark-namespace)]
    (let [path
          (or output-path
              (benchmark/environment-value
               "HPT1_BENCHMARK_OUT"
               "../benchmarks/hpt1-flat-map/evidence.edn"))
          entry-counts
          (benchmark/parse-entry-counts
           (System/getenv "HPT1_BENCHMARK_COUNTS"))
          warmup-count
          (Long/parseLong
           (benchmark/environment-value
            "HPT1_BENCHMARK_WARMUPS"
            (str benchmark/default-warmup-count)))
          sample-count
          (Long/parseLong
           (benchmark/environment-value
            "HPT1_BENCHMARK_SAMPLES"
            (str benchmark/default-sample-count)))
          runtime
          (l/rt benchmark-namespace :postgres)
          put-map-pointer benchmark-put-map
          map-shape-pointer benchmark-map-shape]
      (l/rt:setup runtime benchmark-module)
      (try
        (let [evidence
              (with-redefs
               [benchmark/benchmark-put-map put-map-pointer
                benchmark/benchmark-map-shape map-shape-pointer]
                (benchmark/benchmark-evidence
                 entry-counts warmup-count sample-count))
              _ (validate-evidence!
                 evidence entry-counts sample-count)
              written
              (write-evidence-atomically! path evidence)]
          (println "Wrote" written)
          written)
        (finally
          (bounded-teardown! runtime benchmark-module))))))

(defn -main
  [& [output-path]]
  (let [exit-code
        (try
          (run-benchmark! output-path)
          0
          (catch Throwable error
            (binding [*out* *err*]
              (println "HPT1 flat-map benchmark failed:"
                       (.getMessage error))
              (.printStackTrace error))
            1))]
    (shutdown-agents)
    (flush)
    (binding [*out* *err*]
      (flush))
    (System/exit exit-code)))
