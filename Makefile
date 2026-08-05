.PHONY: db-sql db-contracts hal-check hal-test

db-sql:
	cd db && lein sql

db-contracts:
	cd db && lein contracts

hal-check:
	hara check hal

hal-test:
	hara test hal
