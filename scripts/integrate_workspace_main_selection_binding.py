from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise SystemExit(f"marker not found for {label}")
    return text.replace(old, new, 1)


main_path = Path("db/src/gwdb/ledger/workspace_main.clj")
main = main_path.read_text()

acceptance_table = '''(deftype.pg WorkspaceMainAcceptance
  "Rebuildable projection of one canonical accepted-main attestation."
  {:added "0.16"}
  [:acceptance-root   {:type :bytea :primary true}
   :workspace-id-root {:type :bytea :required true}
   :authority-root    {:type :bytea :required true}
   :expected-root     {:type :bytea}
   :candidate-root    {:type :bytea :required true}
   :policy-root       {:type :bytea :required true}
   :review-roots-root {:type :bytea :required true}
   :recorded-at       {:type :long :required true}])
'''
selection_table = acceptance_table + '''
(deftype.pg WorkspaceMainSelection
  "Append-only binding proving that one acceptance caused a successful main CAS."
  {:added "0.17"}
  [:acceptance-root   {:type :bytea :primary true}
   :workspace-id-root {:type :bytea :required true}
   :authority-root    {:type :bytea :required true}
   :expected-root     {:type :bytea}
   :candidate-root    {:type :bytea :required true}
   :policy-root       {:type :bytea :required true}
   :ref-version       {:type :long :required true}
   :network           {:type :text :required true}
   :transaction-root  {:type :bytea :required true}
   :receipt-root      {:type :bytea :required true}
   :block-root        {:type :bytea :required true}
   :recorded-at       {:type :long :required true}])
'''
if "(deftype.pg WorkspaceMainSelection" not in main:
    main = replace_once(
        main, acceptance_table, selection_table, "main selection table")

selection_functions = '''

(defn.pg workspace-main-selection-row
  {:added "0.17"}
  [:bytea i-acceptance-root]
  (return
   (pg/t:get -/WorkspaceMainSelection
             {:where {:acceptance-root i-acceptance-root}})))

(defn.pg ^{:- [:boolean]}
  workspace-main-selection-valid
  "Verifies the append-only CAS, transaction, receipt and block binding."
  {:added "0.17"}
  [:bytea i-acceptance-root]
  (let [o-selection (-/workspace-main-selection-row i-acceptance-root)
        o-acceptance
        (pg/case [o-selection :is-null]
                 nil
                 :else
                 (-/workspace-main-acceptance-row i-acceptance-root))
        o-transaction
        (pg/case [o-selection :is-null]
                 nil
                 :else
                 (transaction/transaction-get
                  (:bytea (:->> o-selection "transaction_root"))))
        o-receipt
        (pg/case [o-selection :is-null]
                 nil
                 :else
                 (transaction/transaction-receipt-get
                  (:bytea (:->> o-selection "receipt_root"))))
        o-block
        (pg/case [o-selection :is-null]
                 nil
                 :else
                 (block/block-get
                  (:bytea (:->> o-selection "block_root"))))
        o-binding
        (pg/case [o-selection :is-null]
                 nil
                 :else
                 (pg/t:get
                  block/BlockTransaction
                  {:where
                   {:block-root
                    (:bytea (:->> o-selection "block_root"))
                    :transaction-root
                    (:bytea (:->> o-selection "transaction_root"))
                    :receipt-root
                    (:bytea (:->> o-selection "receipt_root"))}}))
        (:bytea v-operation-root)
        (pg/case [o-selection :is-null]
                 nil
                 :else
                 (op/constant i-acceptance-root))]
    (return
     (and [o-selection :is-not-null]
          [o-acceptance :is-not-null]
          [o-transaction :is-not-null]
          [o-receipt :is-not-null]
          [o-block :is-not-null]
          [o-binding :is-not-null]
          (-/workspace-main-acceptance-valid i-acceptance-root)
          (== (:bytea (:->> o-selection "workspace_id_root"))
              (:bytea (:->> o-acceptance "workspace_id_root")))
          (== (:bytea (:->> o-selection "authority_root"))
              (:bytea (:->> o-acceptance "authority_root")))
          (== (:bytea (:->> o-selection "expected_root"))
              (:bytea (:->> o-acceptance "expected_root")))
          (== (:bytea (:->> o-selection "candidate_root"))
              (:bytea (:->> o-acceptance "candidate_root")))
          (== (:bytea (:->> o-selection "policy_root"))
              (:bytea (:->> o-acceptance "policy_root")))
          (== (:bigint (:->> o-selection "recorded_at"))
              (:bigint (:->> o-acceptance "recorded_at")))
          (>= (:bigint (:->> o-selection "ref_version")) 1)
          (== (:text (:->> o-transaction "network"))
              (:text (:->> o-selection "network")))
          (== (:bytea (:->> o-transaction "origin"))
              (:bytea (:->> o-selection "authority_root")))
          (== (:bytea (:->> o-transaction "op_root"))
              v-operation-root)
          (== (:bytea (:->> o-receipt "transaction_root"))
              (:bytea (:->> o-selection "transaction_root")))
          (== (:text (:->> o-receipt "status")) "ok")
          (== (:bytea (:->> o-receipt "result_root"))
              i-acceptance-root)
          (== (:bytea (:->> o-receipt "previous_state_root"))
              (:bytea (:->> o-block "previous_state_root")))
          (== (:bytea (:->> o-receipt "state_root"))
              (:bytea (:->> o-block "state_root")))
          (== (:text (:->> o-block "network"))
              (:text (:->> o-selection "network")))
          (== (:bigint (:->> o-block "timestamp"))
              (:bigint (:->> o-selection "recorded_at")))
          (block/block-valid
           (:bytea (:->> o-selection "block_root")))
          (transaction/transaction-signed-valid
           (:bytea (:->> o-selection "transaction_root"))
           (:text (:->> o-selection "network"))
           (:bytea (:->> o-block "previous_state_root")))))))

(defn.pg ^{:- [:bytea]}
  workspace-main-selection-put
  "Records the exact successful main CAS and its canonical ledger evidence."
  {:added "0.17"}
  [:text i-network
   :bytea i-acceptance-root
   :bytea i-workspace-id-root
   :bytea i-authority-root
   :bytea i-expected-root
   :bytea i-candidate-root
   :bytea i-policy-root
   :bigint i-ref-version
   :bytea i-transaction-root
   :bytea i-receipt-root
   :bytea i-block-root
   :bigint i-recorded-at]
  (let [o-existing (-/workspace-main-selection-row i-acceptance-root)]
    (when [o-existing :is-not-null]
      (pg/assert (-/workspace-main-selection-valid i-acceptance-root)
                 [:ledger/workspace-main-selection-conflict])
      (return i-acceptance-root))
    (let [o-insert
          (pg/t:insert
           -/WorkspaceMainSelection
           {:acceptance-root i-acceptance-root
            :workspace-id-root i-workspace-id-root
            :authority-root i-authority-root
            :expected-root i-expected-root
            :candidate-root i-candidate-root
            :policy-root i-policy-root
            :ref-version i-ref-version
            :network i-network
            :transaction-root i-transaction-root
            :receipt-root i-receipt-root
            :block-root i-block-root
            :recorded-at i-recorded-at})
          _ (pg/assert (-/workspace-main-selection-valid i-acceptance-root)
                       [:ledger/invalid-workspace-main-selection])]
      (return i-acceptance-root))))
'''
if "(defn.pg workspace-main-selection-row" not in main:
    import_marker = "\n\n(defn.pg ^{:- [:bytea]}\n  workspace-main-acceptance-import"
    if import_marker not in main:
        raise SystemExit("marker not found for selection functions")
    main = main.replace(import_marker, selection_functions + import_marker, 1)

old_binding = '''          o-bound
          (block/block-transaction-bind
           v-block-root 0 v-receipt-root)]'''
new_binding = '''          o-bound
          (block/block-transaction-bind
           v-block-root 0 v-receipt-root)
          (:bytea v-selection-root)
          (-/workspace-main-selection-put
           i-network v-acceptance-root
           i-workspace-id-root v-address-root i-expected-root
           i-candidate-root i-policy-root
           (:bigint (:->> o-cas "version"))
           v-transaction-root v-receipt-root v-block-root
           i-recorded-at)]'''
if old_binding in main:
    main = main.replace(old_binding, new_binding, 1)
elif "(-/workspace-main-selection-put" not in main:
    raise SystemExit("marker not found for main selection insertion")

main_path.write_text(main)


release_path = Path("db/src/gwdb/ledger/workspace_release.clj")
release = release_path.read_text()
start_marker = "(defn.pg accepted-main-evidence-row"
end_marker = "\n\n(defn.pg ^{:- [:boolean]}\n  accepted-main-evidence-valid"
start = release.find(start_marker)
end = release.find(end_marker, start)
if start < 0 or end < 0:
    raise SystemExit("marker not found for accepted-main evidence replacement")
new_evidence = '''(defn.pg accepted-main-evidence-row
  "Returns the exact append-only main-selection binding for an acceptance."
  {:added "0.17"}
  [:bytea i-acceptance-root]
  (return
   (workspace-main/workspace-main-selection-row i-acceptance-root)))

(defn.pg ^{:- [:text]}
  accepted-main-evidence-error
  "Proves the acceptance caused a successful main CAS on the current chain."
  {:added "0.17"}
  [:text i-network :bytea i-acceptance-root]
  (let [o-acceptance
        (workspace-main/workspace-main-acceptance-row i-acceptance-root)
        o-selection
        (workspace-main/workspace-main-selection-row i-acceptance-root)
        o-head (block/head-get i-network)]
    (cond [o-acceptance :is-null]
          (return "workspace/release-acceptance-not-found")

          (not
           (workspace-main/workspace-main-acceptance-valid
            i-acceptance-root))
          (return "workspace/invalid-release-acceptance")

          [o-selection :is-null]
          (return "workspace/release-acceptance-not-selected")

          (not
           (workspace-main/workspace-main-selection-valid
            i-acceptance-root))
          (return "workspace/invalid-release-acceptance-selection")

          [o-head :is-null]
          (return "workspace/release-network-not-found")

          (not
           (== (:text (:->> o-selection "network")) i-network))
          (return "workspace/release-acceptance-network-mismatch")

          (not
           (-/block-ancestor
            (:bytea (:->> o-selection "block_root"))
            (:bytea (:->> o-head "block_root"))))
          (return "workspace/release-acceptance-not-canonical")

          :else
          (return nil))))'''
release = release[:start] + new_evidence + release[end:]
release_path.write_text(release)


test_path = Path("db/test/gwdb/ledger/workspace_release_test.clj")
test = test_path.read_text()
acceptance_marker = '''        acceptance-root
        (hex-bytes (json-field main-result "acceptance_root"))

        uncommitted-acceptance-root'''
acceptance_replacement = '''        acceptance-root
        (hex-bytes (json-field main-result "acceptance_root"))
        acceptance-selection-row
        (workspace-main/workspace-main-selection-row acceptance-root)

        uncommitted-acceptance-root'''
test = replace_once(
    test, acceptance_marker, acceptance_replacement,
    "release test selection fixture")
results_marker = '''     (json-field main-result "status")
     (workspace-release/accepted-main-evidence-valid
      network acceptance-root)'''
results_replacement = '''     (json-field main-result "status")
     (workspace-main/workspace-main-selection-valid acceptance-root)
     (= (:bytea (json-field acceptance-selection-row "candidate_root")) c0)
     (= (:bytea (json-field acceptance-selection-row "policy_root")) policy-root)
     (workspace-release/accepted-main-evidence-valid
      network acceptance-root)'''
test = replace_once(
    test, results_marker, results_replacement,
    "release test selection assertions")
expected_marker = '''  => ["ok" "ok" "ok" "ok" "ok"
      true false :rejected :rejected :rejected'''
expected_replacement = '''  => ["ok" "ok" "ok" "ok" "ok"
      true true true true false :rejected :rejected :rejected'''
test = replace_once(
    test, expected_marker, expected_replacement,
    "release test expected selection assertions")
test_path.write_text(test)


doc_path = Path("docs/workspace-release-admission.md")
doc = doc_path.read_text()
needle = '''A structurally valid acceptance value is not sufficient. Release admission also
requires an `ok` transaction receipt whose result is the acceptance root, a
matching transaction/receipt block binding, a valid signed transaction, matching
receipt and block state roots, and a block on the current network-head ancestry.
'''
replacement = '''A structurally valid acceptance value is not sufficient. `workspace-main-submit`
records an append-only `WorkspaceMainSelection` binding only after the exact main
CAS, signed transaction, receipt, block commit and receipt binding all succeed.
Release admission requires that binding to match the acceptance, transaction,
receipt and block and requires its block to remain on the current network-head
ancestry. A generic transaction that merely returns an acceptance-shaped root
therefore cannot masquerade as the transition that advanced `main`.
'''
if needle in doc:
    doc = doc.replace(needle, replacement, 1)
elif "WorkspaceMainSelection" not in doc:
    raise SystemExit("marker not found for release selection documentation")
doc_path.write_text(doc)
