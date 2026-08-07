(ns ledger.hpt1-flat-map-benchmark-runner
  (:require [ledger.hpt1-flat-map-benchmark :as benchmark]))

(def benchmark-namespace
  'ledger.hpt1-flat-map-benchmark)

(defn -main
  [& args]
  ;; Leiningen invokes -main while *ns* is normally `user`, whereas l/script-
  ;; registered the PostgreSQL runtime against the benchmark namespace. Restore
  ;; that namespace for runtime lookup and pointer invocation, matching code.test.
  (binding [*ns* (the-ns benchmark-namespace)]
    (apply benchmark/-main args)))
