SHELL := /bin/bash
WORKFLOW_DIR := $(shell pwd)
SCRIPTS_DIR := $(WORKFLOW_DIR)/scripts
TESTS_DIR := $(WORKFLOW_DIR)/tests

.PHONY: help lint test test-unit test-integration test-golden test-chaos test-smoke clean

help:
	@echo "design-review workflow"
	@echo ""
	@echo "Targets:"
	@echo "  lint              — shellcheck 所有 *.sh"
	@echo "  test              — 跑全部 bats 测试（unit + integration）"
	@echo "  test-unit         — 仅跑 unit"
	@echo "  test-integration  — 仅跑 integration（需 mock-claude.sh）"
	@echo "  test-golden       — 黄金对照"
	@echo "  test-chaos        — 混沌注入"
	@echo "  test-smoke        — 真实 LLM smoke（耗 token）"
	@echo "  clean             — 清理 /tmp/design-review-runs/"

lint:
	@echo "=== shellcheck ==="
	@find $(SCRIPTS_DIR) $(TESTS_DIR) -name '*.sh' -type f -print0 | \
		xargs -0 -r shellcheck --severity=warning

test: test-unit test-integration

test-unit:
	@echo "=== bats unit ==="
	@bats $(TESTS_DIR)/unit/

test-integration:
	@echo "=== bats integration ==="
	@if [ -d $(TESTS_DIR)/integration ] && [ -n "$$(ls -A $(TESTS_DIR)/integration 2>/dev/null)" ]; then \
		bats $(TESTS_DIR)/integration/; \
	else \
		echo "(integration 测试待 M3 落地)"; \
	fi

test-golden:
	@if [ -d $(TESTS_DIR)/golden ] && [ -n "$$(ls -A $(TESTS_DIR)/golden 2>/dev/null)" ]; then \
		bats $(TESTS_DIR)/golden/; \
	else echo "(golden 待 M5)"; fi

test-chaos:
	@if [ -d $(TESTS_DIR)/chaos ] && [ -n "$$(ls -A $(TESTS_DIR)/chaos 2>/dev/null)" ]; then \
		bats $(TESTS_DIR)/chaos/; \
	else echo "(chaos 待 M5)"; fi

test-smoke:
	@if [ -f $(TESTS_DIR)/smoke/run.sh ]; then bash $(TESTS_DIR)/smoke/run.sh; else echo "(smoke 待 M5)"; fi

clean:
	@rm -rf /tmp/design-review-runs/*
	@echo "已清理 /tmp/design-review-runs/"
