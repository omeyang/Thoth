# Makefile for adversarial-review workflow
SCRIPTS := $(wildcard scripts/*.sh scripts/lib/*.sh)

.PHONY: lint test test-unit test-integration help

help:
	@echo "Targets: lint, test, test-unit, test-integration"

lint:
	@bash -c 'shopt -s nullglob; files=($(SCRIPTS) hooks/*.tmpl); shellcheck -e SC1091 -e SC2155 "$${files[@]}"'

test: test-unit test-integration

test-unit:
	bats tests/unit/

test-integration:
	bats tests/integration/
