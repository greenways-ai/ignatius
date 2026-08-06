(ns gwdb.ledger.protocol-runtime
  (:require [tahto.core :as l]
            [gwdb.ledger.runtime-v2 :as runtime-v2]))

(l/script :postgres
  {:require [[gwdb.ledger.runtime-v2 :as runtime-v2]]
   :config {:dbname "gw-ledger-test"}
   :static {:application ["gw"]
            :all {:schema ["gw_ledger"]}}})

(defn.pg ^{:- [:jsonb]}
  protocol-execute
  "Compatibility entrypoint for the recursive deterministic runtime."
  {:added "0.7"}
  [:bytea i-context-root :bytea i-op-root]
  (return (runtime-v2/execute i-context-root i-op-root)))