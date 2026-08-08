(ns ledger.hpt1-flat-map-benchmark
  (:require [clojure.data.json :as json]
            [clojure.java.io :as io]
            [clojure.pprint :as pprint]
            [clojure.string :as str]
            [tahto.core :as l]
            [postgres.core :as pg]
            [gwdb.ledger.base :as base]
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
             [gwdb.ledger.base :as base :primary true]
             [gwdb.ledger.cell :as cell]
             [gwdb.ledger.value :as value]]
   :static {:application ["gw"]
            :seed ["gw_ledger"]
            :all {:schema ["gw_ledger"]}}})

(defn.pg ^{:- [:text]}
  benchmark-put-string
  "Stores one canonical string and returns its root as lowercase hex text."
  {:added "0.18"}
  [:text i-value]
  (return
   (pg/encode (value/put-string i-value) "hex")))

(defn.pg ^{:- [:text]}
  benchmark-put-map
  "Builds a map from a JSON text array of canonical key/value root hex."
  {:added "0.18"}
  [:text i-root-pairs-json]
  (return
   (pg/encode
    (value/put-map (:jsonb i-root-pairs-json))
    "hex")))

(defn.pg ^{:- [:text]}
  benchmark-map-get
  "Looks up one root through a benchmark-only hex-text JDBC boundary."
  {:added "0.18"}
  [:text i-map-root-hex :text i-key-root-hex]
  (return
   (pg/encode
    (value/map-get
     (pg/decode i-map-root-hex "hex")
     (pg/decode i-key-root-hex "hex"))
    "hex")))

(defn.pg ^{:- [:text]}
  benchmark-map-assoc
  "Associates one root through a benchmark-only hex-text JDBC boundary."
  {:added "0.18"}
  [:text i-map-root-hex
   :text i-key-root-hex
   :text i-value-root-hex]
  (return
   (pg/encode
    (value/map-assoc
     (pg/decode i-map-root-hex "hex")
     (pg/decode i-key-root-hex "hex")
     (pg/decode i-value-root-hex "hex"))
    "hex")))

(defn.pg ^{:- [:jsonb]}
  benchmark-map-shape
  "Returns the stored payload bytes and derived key/value reference counts."
  {:added "0.18"}
  [:text i-map-root-hex]
  (let [(:bytea v-map-root) (pg/decode i-map-root-hex "hex")
        o-cell (cell/cell-by-hash v-map-root)
        _ (pg/assert [o-cell :is-not-null]
                     [:ledger/missing-benchmark-map])]
    (return
     (pg/jsonb-build-object
      "payload_bytes" (:integer (:->> o-cell "byte_size"))
      "key_refs" (cell/cell-ref-count v-map-root "key")
      "value_refs" (cell/cell-ref-count v-map-root "value")))))

(def default-entry-counts [16 64 256 1024 4096])
(def default-warmup-count 2)
(def default-sample-count 7)

(defn json-object
  "Normalises JSONB values returned by supported JDBC drivers.

  The ordinary PostgreSQL driver may decode JSONB into a Clojure map, while
  pgjdbc-ng exposes its textual JSON representation. Benchmark evidence should
  not depend on that driver-specific choice."
  [value]
  (cond
    (map? value)
    value

    (string? value)
    (json/read-str value)

    (nil? value)
    nil

    :else
    (json/read-str (str value))))

(defn json-field
  [value field]
  (let [object (json-object value)]
    (or (get object field)
        (get object (keyword field)))))

(defn environment-value
  [name fallback]
  (let [value (System/getenv name)]
    (if (or (nil? value) (= "" value))
      fallback
      value)))

(defn parse-entry-counts
  [text]
  (if (or (nil? text) (= "" text))
    default-entry-counts
    (mapv #(Long/parseLong (str/trim %))
          (str/split text #","))))

(defn fixed-name
  [prefix position]
  (format "%s%08d" prefix (long position)))

(defn put-string-root
  [text]
  (-/benchmark-put-string text))

(defn map-shape
  [root]
  (let [value (-/benchmark-map-shape root)]
    {:payload-bytes (long (json-field value "payload_bytes"))
     :key-refs (long (json-field value "key_refs"))
     :value-refs (long (json-field value "value_refs"))}))

(defn timed
  [f]
  (let [started (System/nanoTime)
        result (f)
        completed (System/nanoTime)]
    {:elapsed-ns (- completed started)
     :result result}))

(defn percentile
  [samples proportion]
  (let [ordered (vec (sort samples))
        count-value (count ordered)
        rank (long (Math/ceil (* proportion count-value)))
        position (max 0 (min (- count-value 1) (- rank 1)))]
    (get ordered position)))

(defn sample-summary
  [samples]
  {:sample-count (count samples)
   :samples-ns samples
   :median-ns (percentile samples 0.50)
   :p95-ns (percentile samples 0.95)})

(defn build-fixture
  [entry-count]
  (let [built
        (loop [position 0
               root-pairs []
               key-roots []
               value-roots []]
          (if (>= position entry-count)
            {:root-pairs root-pairs
             :key-roots key-roots
             :value-roots value-roots}
            (let [key-root
                  (put-string-root (fixed-name "k" (* position 2)))
                  value-root
                  (put-string-root (fixed-name "v" position))]
              (recur
               (+ position 1)
               (conj root-pairs key-root value-root)
               (conj key-roots key-root)
               (conj value-roots value-root)))))
        key-roots (:key-roots built)
        value-roots (:value-roots built)
        measured
        (timed
         #(-/benchmark-put-map
           (json/write-str (:root-pairs built))))
        map-root (:result measured)
        middle-position (quot entry-count 2)]
    {:entry-count entry-count
     :map-root map-root
     :key-roots key-roots
     :value-roots value-roots
     :first-key (get key-roots 0)
     :middle-key (get key-roots middle-position)
     :last-key (get key-roots (- entry-count 1))
     :first-value (get value-roots 0)
     :middle-value (get value-roots middle-position)
     :last-value (get value-roots (- entry-count 1))
     :missing-before-key (put-string-root "j99999999")
     :missing-after-key (put-string-root "z00000000")
     :construction
     (merge
      {:elapsed-ns (:elapsed-ns measured)
       :write-model :canonical-map-cell-and-derived-refs
       :new-map-cells 1
       :derived-ref-writes (* entry-count 2)}
      (map-shape map-root))}))

(defn warm-and-sample
  [warmup-count sample-count f]
  (dotimes [position warmup-count]
    (f position))
  (sample-summary
   (mapv
    (fn [position]
      (:elapsed-ns (timed #(f (+ warmup-count position)))))
    (range sample-count))))

(defn measured-mutations
  [warmup-count sample-count derived-ref-writes f]
  (dotimes [position warmup-count]
    (f position))
  (let [observations
        (mapv
         (fn [position]
           (let [measured
                 (timed #(f (+ warmup-count position)))]
             {:elapsed-ns (:elapsed-ns measured)
              :result-root (:result measured)}))
         (range sample-count))]
    {:sample-count sample-count
     :write-model :canonical-map-cell-and-derived-refs
     :new-map-cells-per-operation 1
     :derived-ref-writes-per-operation derived-ref-writes
     :samples-ns (mapv :elapsed-ns observations)
     :median-ns
     (percentile (mapv :elapsed-ns observations) 0.50)
     :p95-ns
     (percentile (mapv :elapsed-ns observations) 0.95)
     :observations observations}))

(defn get-benchmark
  [fixture warmup-count sample-count]
  (let [map-root (:map-root fixture)
        expected
        {:first (:first-value fixture)
         :middle (:middle-value fixture)
         :last (:last-value fixture)
         :missing-before nil
         :missing-after nil}
        scenarios
        {:first (:first-key fixture)
         :middle (:middle-key fixture)
         :last (:last-key fixture)
         :missing-before (:missing-before-key fixture)
         :missing-after (:missing-after-key fixture)}]
    (reduce-kv
     (fn [out scenario key-root]
       (let [observed
             (-/benchmark-map-get map-root key-root)
             _ (when (not (= observed (get expected scenario)))
                 (throw
                  (ex-info
                   "flat-map get returned an unexpected root"
                   {:scenario scenario
                    :expected (get expected scenario)
                    :observed observed})))]
         (assoc
          out scenario
          (warm-and-sample
           warmup-count sample-count
           (fn [_]
             (-/benchmark-map-get map-root key-root))))))
     {}
     scenarios)))

(defn replacement-roots
  [entry-count scenario total-count]
  (mapv
   (fn [position]
     (put-string-root
      (format "replacement-%d-%s-%08d"
              (long entry-count) (name scenario) (long position))))
   (range total-count)))

(defn inserted-roots
  [entry-count scenario total-count]
  {:keys
   (mapv
    (fn [position]
      (put-string-root
       (if (= scenario :append)
         (format "z%d-%08d" (long entry-count) (long position))
         (fixed-name "k" (+ 1 (* position 2))))))
    (range total-count))
   :values
   (mapv
    (fn [position]
      (put-string-root
       (format "inserted-%d-%s-%08d"
               (long entry-count) (name scenario) (long position))))
    (range total-count))})

(defn assoc-existing-benchmark
  [fixture warmup-count sample-count]
  (let [map-root (:map-root fixture)
        entry-count (:entry-count fixture)
        total-count (+ warmup-count sample-count)
        scenarios
        {:first (:first-key fixture)
         :middle (:middle-key fixture)
         :last (:last-key fixture)}]
    (reduce-kv
     (fn [out scenario key-root]
       (let [roots
             (replacement-roots entry-count scenario total-count)]
         (assoc
          out scenario
          (measured-mutations
           warmup-count sample-count (* entry-count 2)
           (fn [position]
             (-/benchmark-map-assoc
              map-root key-root (get roots position)))))))
     {}
     scenarios)))

(defn assoc-new-benchmark
  [fixture warmup-count sample-count]
  (let [map-root (:map-root fixture)
        entry-count (:entry-count fixture)
        total-count (+ warmup-count sample-count)]
    (reduce
     (fn [out scenario]
       (let [roots
             (inserted-roots entry-count scenario total-count)
             key-roots (:keys roots)
             value-roots (:values roots)]
         (assoc
          out scenario
          (measured-mutations
           warmup-count sample-count (* (+ entry-count 1) 2)
           (fn [position]
             (-/benchmark-map-assoc
              map-root
              (get key-roots position)
              (get value-roots position)))))))
     {}
     [:append :interior])))

(defn benchmark-entry-count
  [entry-count warmup-count sample-count]
  (let [fixture (build-fixture entry-count)]
    {:status :ok
     :entry-count entry-count
     :map-root (:map-root fixture)
     :construction (:construction fixture)
     :get (get-benchmark fixture warmup-count sample-count)
     :assoc-existing
     (assoc-existing-benchmark fixture warmup-count sample-count)
     :assoc-new
     (assoc-new-benchmark fixture warmup-count sample-count)}))

(defn benchmark-evidence
  [entry-counts warmup-count sample-count]
  {:evidence/version 1
   :evidence/kind :hcv1-flat-map-jdbc-baseline
   :generated-at (str (java.time.Instant/now))
   :timing/scope :jdbc-round-trip
   :timing/clock :system-nanotime
   :root-transport :lowercase-hex-text
   :write-accounting :canonical-structural-model
   :warmup-count warmup-count
   :sample-count sample-count
   :toolchain
   {:ignatius-commit
    (environment-value "IGNATIUS_COMMIT" "unknown")
    :hara-commit
    (environment-value "HARA_COMMIT" "unknown")
    :foundation-commit
    (environment-value "FOUNDATION_COMMIT" "unknown")
    :postgres-image
    (environment-value
     "POSTGRES_IMAGE" "gw-ledger-postgres:15-pgsodium")}
   :environment
   {:java-version (System/getProperty "java.version")
    :os-name (System/getProperty "os.name")
    :os-version (System/getProperty "os.version")
    :available-processors
    (.availableProcessors (Runtime/getRuntime))}
   :entry-counts entry-counts
   :results
   (mapv
    (fn [entry-count]
      (try
        (benchmark-entry-count
         entry-count warmup-count sample-count)
        (catch Throwable error
          {:status :error
           :entry-count entry-count
           :error/class (.getName (class error))
           :error/message (.getMessage error)
           :error/data (ex-data error)})))
    entry-counts)})

(defn write-evidence!
  [path evidence]
  (let [file (io/file path)]
    (io/make-parents file)
    (with-open [writer (io/writer file)]
      (binding [*out* writer]
        (pprint/pprint evidence)))
    (.getPath file)))

(defn -main
  [& [output-path]]
  (let [path
        (or output-path
            (environment-value
             "HPT1_BENCHMARK_OUT"
             "../benchmarks/hpt1-flat-map/evidence.edn"))
        entry-counts
        (parse-entry-counts
         (System/getenv "HPT1_BENCHMARK_COUNTS"))
        warmup-count
        (Long/parseLong
         (environment-value
          "HPT1_BENCHMARK_WARMUPS"
          (str default-warmup-count)))
        sample-count
        (Long/parseLong
         (environment-value
          "HPT1_BENCHMARK_SAMPLES"
          (str default-sample-count)))]
    (l/rt:setup :postgres)
    (try
      (let [evidence
            (benchmark-evidence
             entry-counts warmup-count sample-count)]
        (println "Wrote"
                 (write-evidence! path evidence)))
      (finally
        ;; The evidence file is complete before cleanup. Stop only the runtime
        ;; created by this runner; the Leiningen host owns global module shutdown.
        (try
          (l/rt:teardown :postgres)
          (catch Throwable cleanup-error
            (binding [*out* *err*]
              (println "PostgreSQL benchmark cleanup warning:"
                       (.getMessage cleanup-error)))))))))
