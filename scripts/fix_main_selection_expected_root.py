from pathlib import Path

path = Path("db/src/gwdb/ledger/workspace_main.clj")
text = path.read_text()

old_let = '''        o-transaction
        (pg/case [o-selection :is-null]
                 nil
                 :else
                 (transaction/transaction-get
                  (:bytea (:->> o-selection "transaction_root"))))'''
new_let = '''        (:bytea v-selection-expected-root)
        (pg/case [o-selection :is-null]
                 nil
                 :else
                 (:bytea (:->> o-selection "expected_root")))
        (:bytea v-acceptance-expected-root)
        (pg/case [o-acceptance :is-null]
                 nil
                 :else
                 (:bytea (:->> o-acceptance "expected_root")))
        o-transaction
        (pg/case [o-selection :is-null]
                 nil
                 :else
                 (transaction/transaction-get
                  (:bytea (:->> o-selection "transaction_root"))))'''
if old_let not in text:
    raise SystemExit("selection expected-root let marker not found")
text = text.replace(old_let, new_let, 1)

old_comparison = '''          (== (:bytea (:->> o-selection "expected_root"))
              (:bytea (:->> o-acceptance "expected_root")))'''
new_comparison = '''          (or (and [v-selection-expected-root :is-null]
                   [v-acceptance-expected-root :is-null])
              (and [v-selection-expected-root :is-not-null]
                   [v-acceptance-expected-root :is-not-null]
                   (== v-selection-expected-root
                       v-acceptance-expected-root)))'''
if old_comparison not in text:
    raise SystemExit("selection expected-root comparison marker not found")
text = text.replace(old_comparison, new_comparison, 1)

path.write_text(text)
