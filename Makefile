.PHONY: setup verify db-sql db-contracts hal-check hal-test extension-sha-test

setup:
	bash scripts/setup-dependencies

verify: setup hal-check hal-test db-sql db-contracts extension-sha-test
	git diff --exit-code -- db/sql/full.sql db/contracts/ledger-client/generated.ts

db-sql:
	cd db && lein sql

db-contracts:
	cd db && lein contracts

hal-check:
	hara --project hal check

hal-test:
	hara --project hal test

extension-sha-test:
	cargo test --locked --manifest-path extensions/sha/rust/Cargo.toml
