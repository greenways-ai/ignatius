HPT0_BENCHMARK_OUT ?= ../benchmarks/hpt1-flat-map/evidence.edn
HARA_BIN ?= hara

.PHONY: setup verify boundary-check migration-test chain-release-test db-sql db-contracts db-hal-parity db-hal-check db-hal-test hal-check hal-test extension-sha-test hpt1-flat-map-benchmark

setup:
	bash scripts/setup-dependencies

verify: setup boundary-check migration-test chain-release-test db-hal-parity hal-check hal-test db-sql db-contracts extension-sha-test
	git diff --exit-code -- db/sql/full.sql db/contracts/ledger-client/generated.ts

boundary-check:
	bash scripts/check-architecture-boundaries

migration-test:
	bash scripts/test-chain-migrations

chain-release-test:
	bash scripts/test-chain-release

db-sql:
	cd db && lein sql

db-contracts:
	cd db && lein contracts

db-hal-parity:
	bash scripts/check-ledger-hal-parity

hal-check:
	$(HARA_BIN) --project hal check

hal-test:
	$(HARA_BIN) --project hal test

db-hal-check:
	$(HARA_BIN) --project $(CURDIR)/db check

db-hal-test:
	$(HARA_BIN) --allow-postgres --allow-process --project $(CURDIR)/db test

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
	    '[org.apache.commons/commons-math3 "3.6.1"]' \
	    '[com.impossibl.pgjdbc-ng/pgjdbc-ng "0.8.9" :exclusions [io.netty/netty-common io.netty/netty-buffer io.netty/netty-transport io.netty/netty-codec io.netty/netty-handler io.netty/netty-transport-native-unix-common]]' \
	    '[io.netty/netty-all "4.1.118.Final"]' -- \
	    run -m ledger.hpt1-flat-map-benchmark-runner \
	    "$(HPT0_BENCHMARK_OUT)"
