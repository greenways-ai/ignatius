.PHONY: setup verify db-sql db-contracts hal-check hal-test extension-sha-test

setup:
	bash scripts/setup-dependencies

verify: setup db-sql db-contracts extension-sha-test
	git diff --exit-code -- db/sql/full.sql db/contracts/ledger-client/generated.ts

db-sql:
	cd db && lein sql

db-contracts:
	cd db && lein contracts

hal-check:
	hara check hal

hal-test:
	hara test hal

extension-sha-test:
	cargo test --locked --manifest-path extensions/sha/rust/Cargo.toml
