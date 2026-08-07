.PHONY: setup verify db-sql db-contracts hal-check hal-test extension-sha-test hpt1-flat-map-benchmark

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

hpt1-flat-map-benchmark: setup
	docker build -t gw-ledger-postgres:15-pgsodium -f db/Dockerfile.postgres15-pgsodium db
	cd db && \
	  IGNATIUS_COMMIT="$$(git -C .. rev-parse HEAD)" \
	  HARA_COMMIT="$$(git -C ../.local/hara.lang rev-parse HEAD)" \
	  FOUNDATION_COMMIT="$$(git -C checkouts/foundation rev-parse HEAD)" \
	  POSTGRES_IMAGE="gw-ledger-postgres:15-pgsodium" \
	  lein update-in :dependencies conj \
	    '[org.clojure/core.rrb-vector "0.1.2"]' \
	    '[org.apache.commons/commons-math3 "3.6.1"]' -- \
	    run -m ledger.hpt1-flat-map-benchmark \
	    ../benchmarks/hpt1-flat-map/evidence.edn
