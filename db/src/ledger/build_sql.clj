(ns ledger.build-sql
  (:require [std.make :as make :refer [def.make]]
            [std.make.project :as project]
            [jvm.namespace.common :as common]
            [clojure.string :as str]
            [tahto.core.compile]))

;; `gwdb.ledger.base` is the single ordered entry point. Its namespace
;; requires establish the dependency order for generated PostgreSQL.
(def.make LEDGER-SCHEMA
  {:tag "gwdb-ledger-schema"
   :build "sql/"
   :default [{:type :module.schema
              :lang :postgres
              :file "full.sql"
              :main 'gwdb.ledger.base
              :emit {:code {:label true}}}]})

(defn build-db
  []
  (let [result (make/build-all LEDGER-SCHEMA)
        path   "sql/full.sql"
        code   (slurp path)]
    ;; The module compiler emits schema seeds with the module entry.  Keep the
    ;; generated full build executable from an empty database by placing the
    ;; seed before the dependency-ordered functions and tables.
    (when-not (str/starts-with? (str/triml code)
                                "CREATE SCHEMA IF NOT EXISTS \"gw_ledger\";")
      (spit path (str "CREATE SCHEMA IF NOT EXISTS \"gw_ledger\";\n\n" code)))
    result))

(defn -main
  [& _]
  (build-db))
