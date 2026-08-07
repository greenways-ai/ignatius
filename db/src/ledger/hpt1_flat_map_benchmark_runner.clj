(ns ledger.hpt1-flat-map-benchmark-runner
  (:require [ledger.hpt1-flat-map-benchmark :as benchmark]
            [tahto.core :as l]
            [postgres.core :as pg]
            [gwdb.ledger.cell :as cell]
            [gwdb.ledger.value :as value]))

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

(defn -main
  [& [output-path]]
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
                 entry-counts warmup-count sample-count))]
          (println "Wrote"
                   (benchmark/write-evidence! path evidence)))
        (finally
          (try
            (l/rt:teardown runtime benchmark-module)
            (catch Throwable cleanup-error
              (binding [*out* *err*]
                (println "PostgreSQL benchmark cleanup warning:"
                         (.getMessage cleanup-error))))))))))
