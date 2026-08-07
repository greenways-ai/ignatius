(ns ledger.hpt1-flat-map-benchmark-runner
  (:require [ledger.hpt1-flat-map-benchmark :as benchmark]
            [tahto.core :as l]))

(def benchmark-namespace
  'ledger.hpt1-flat-map-benchmark)

(def benchmark-module
  'gwdb.ledger.value)

(defn -main
  [& [output-path]]
  ;; Leiningen invokes -main while *ns* is normally `user`, whereas l/script-
  ;; registered the PostgreSQL runtime against the benchmark namespace. Restore
  ;; that namespace for pointer invocation and explicitly install only the value
  ;; module dependency closure. The complete ledger also contains unrelated
  ;; legacy SQL and is not part of this flat-map measurement.
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
          (l/rt benchmark-namespace :postgres)]
      (l/rt:setup runtime benchmark-module)
      (try
        (let [evidence
              (benchmark/benchmark-evidence
               entry-counts warmup-count sample-count)]
          (println "Wrote"
                   (benchmark/write-evidence! path evidence)))
        (finally
          (try
            (l/rt:teardown runtime benchmark-module)
            (catch Throwable cleanup-error
              (binding [*out* *err*]
                (println "PostgreSQL benchmark cleanup warning:"
                         (.getMessage cleanup-error))))))))))
