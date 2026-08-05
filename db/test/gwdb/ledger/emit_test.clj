(ns gwdb.ledger.emit-test
  (:use code.test)
  (:require [clojure.string :as str]
            [tahto.core.impl :as impl]
            [gwdb.ledger.base]
            [gwdb.ledger.cell]))

(defn emit
  [id]
  (impl/emit-entry {:lang :postgres
                    :module 'gwdb.ledger.cell
                    :id id}
                   {:lang :postgres}))

(defn emit-from
  [module id]
  (impl/emit-entry {:lang :postgres
                    :module module
                    :id id}
                   {:lang :postgres}))

^{:refer gwdb.ledger.cell/Cell :added "0.1"}
(fact "cell emits as a ledger schema table"
  (let [sql (emit 'Cell)]
    (str/includes? sql "gw_ledger") => true
    (str/includes? sql "BYTEA") => true))

^{:refer gwdb.ledger.cell/CellRef :added "0.1"}
(fact "cell references emit a composite primary key"
  (let [sql (emit 'CellRef)]
    (str/includes? sql "PRIMARY KEY") => true
    (str/includes? sql "parent_hash") => true))

^{:refer gwdb.ledger.syntax/Syntax :added "0.1"}
(fact "syntax projection emits explicit roots"
  (let [sql (emit-from 'gwdb.ledger.syntax 'Syntax)]
    (str/includes? sql "syntax_root") => true
    (str/includes? sql "metadata_root") => true))

^{:refer gwdb.ledger.state/StateHead :added "0.1"}
(fact "state projection emits a version and height"
  (let [sql (emit-from 'gwdb.ledger.state 'StateHead)]
    (str/includes? sql "state_version") => true
    (str/includes? sql "block_height") => true))

^{:refer gwdb.ledger.account/Account :added "0.1"}
(fact "account projection keeps roots instead of logical values"
  (let [sql (emit-from 'gwdb.ledger.account 'Account)]
    (str/includes? sql "environment_root") => true
    (str/includes? sql "metadata_root") => true
    (str/includes? sql "BYTEA") => true))

^{:refer gwdb.ledger.value/put-string :added "0.1"}
(fact "value constructors are PostgreSQL functions"
  (let [sql (emit-from 'gwdb.ledger.value 'put-string)]
    (str/includes? sql "CREATE OR REPLACE FUNCTION") => true
    (str/includes? sql "put_string_payload") => true)
  (let [sql (emit-from 'gwdb.ledger.value 'put-string-payload)]
    (str/includes? sql "canonical_hash") => true))

^{:refer gwdb.ledger.op/Op :added "0.1"}
(fact "operation projections expose a closed operation descriptor"
  (let [sql (emit-from 'gwdb.ledger.op 'Op)]
    (str/includes? sql "op_kind") => true
    (str/includes? sql "function_root") => true))

^{:refer gwdb.ledger.context/ExecutionContext :added "0.1"}
(fact "execution context stores explicit deterministic inputs"
  (let [sql (emit-from 'gwdb.ledger.context 'ExecutionContext)]
    (str/includes? sql "block_height") => true
    (str/includes? sql "cost_limit") => true
    (str/includes? sql "timestamp") => true))

^{:refer gwdb.ledger.runtime/execute :added "0.1"}
(fact "runtime dispatch is emitted as a PostgreSQL function"
  (let [sql (emit-from 'gwdb.ledger.runtime 'execute)]
    (str/includes? sql "unsupported-op") => true
    (str/includes? sql "unknown-op") => true))

^{:refer gwdb.ledger.primitive/Primitive :added "0.1"}
(fact "primitive descriptors are stored by stable id and arity"
  (let [sql (emit-from 'gwdb.ledger.primitive 'Primitive)]
    (str/includes? sql "primitive_id") => true
    (str/includes? sql "arity") => true))

^{:refer gwdb.ledger.function/Function :added "0.1"}
(fact "function descriptors retain body and closure roots"
  (let [sql (emit-from 'gwdb.ledger.function 'Function)]
    (str/includes? sql "body_root") => true
    (str/includes? sql "closure_root") => true))

^{:refer gwdb.ledger.module/Module :added "0.1"}
(fact "module descriptors pin version and dependency roots"
  (let [sql (emit-from 'gwdb.ledger.module 'Module)]
    (str/includes? sql "module_version") => true
    (str/includes? sql "dependencies_root") => true))

^{:refer gwdb.ledger.iterator/Iterator :added "0.1"}
(fact "iterators are serialisable projections"
  (let [sql (emit-from 'gwdb.ledger.iterator 'Iterator)]
    (str/includes? sql "plan_root") => true
    (str/includes? sql "state_root") => true))

^{:refer gwdb.ledger.transaction/Transaction :added "0.1"}
(fact "transactions retain op, form and runtime roots"
  (let [sql (emit-from 'gwdb.ledger.transaction 'Transaction)]
    (str/includes? sql "op_root") => true
    (str/includes? sql "runtime_root") => true))

^{:refer gwdb.ledger.block/Head :added "0.1"}
(fact "heads are keyed by network and state root"
  (let [sql (emit-from 'gwdb.ledger.block 'Head)]
    (str/includes? sql "network") => true
    (str/includes? sql "state_root") => true))

^{:refer gwdb.ledger.snapshot/Snapshot :added "0.1"}
(fact "snapshots carry codec and hash metadata"
  (let [sql (emit-from 'gwdb.ledger.snapshot 'Snapshot)]
    (str/includes? sql "codec_version") => true
    (str/includes? sql "hash_algorithm") => true))
