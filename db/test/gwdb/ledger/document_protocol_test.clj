(ns gwdb.ledger.document-protocol-test
  (:use code.test)
  (:require [clojure.string :as str]
            [tahto.core.impl :as impl]
            [gwdb.ledger.base]
            [gwdb.ledger.document-protocol]))

(defn emit-protocol
  [id]
  (impl/emit-entry {:lang :postgres
                    :module 'gwdb.ledger.document-protocol
                    :id id}
                   {:lang :postgres}))

^{:refer gwdb.ledger.document-protocol/DocumentChangeBatch :added "0.7"}
(fact "change batches retain ordered operation roots and signed replay context"
  (let [sql (emit-protocol 'DocumentChangeBatch)]
    (str/includes? sql "operation_roots") => true
    (str/includes? sql "base_ast_root") => true
    (str/includes? sql "expected_result_root") => true
    (str/includes? sql "signature") => true))

^{:refer gwdb.ledger.document-protocol/DocumentBatchOperation :added "0.7"}
(fact "batch operations retain individual transformation and result boundaries"
  (let [sql (emit-protocol 'DocumentBatchOperation)]
    (str/includes? sql "position") => true
    (str/includes? sql "transformed_root") => true
    (str/includes? sql "result_root") => true
    (str/includes? sql "conflict") => true))

^{:refer gwdb.ledger.document-protocol/DocumentImportReceipt :added "0.7"}
(fact "environment receipts separate blinded commitments from private roots"
  (let [sql (emit-protocol 'DocumentImportReceipt)]
    (str/includes? sql "submission_commitment") => true
    (str/includes? sql "environment_sequence") => true
    (str/includes? sql "environment_key") => true))

^{:refer gwdb.ledger.document-protocol/document-protocol-signing-payload :added "0.7"}
(fact "signing uses domain-separated bytes rather than JSON"
  (let [sql (emit-protocol 'document-protocol-signing-payload)]
    (str/includes? sql "475744503100") => true
    (str/includes? sql "convert_to") => true))

^{:refer gwdb.ledger.document-protocol/DocumentApproval :added "0.7"}
(fact "approval and delivery bind exact policy revision and AST roots"
  (let [approval (emit-protocol 'DocumentApproval)
        delivery (emit-protocol 'DocumentDelivery)]
    (str/includes? approval "policy_root") => true
    (str/includes? approval "revision_root") => true
    (str/includes? approval "ast_root") => true
    (str/includes? delivery "coverage_root") => true
    (str/includes? delivery "disclosure_mode") => true))
