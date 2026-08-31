# Lux Liquid — Foundry + Security Tooling

-include .env

FORGE := $(HOME)/.foundry/bin/forge
VENV := .venv
UV := uv
PYTHON := $(VENV)/bin/python
SLITHER := $(VENV)/bin/slither
SEMGREP := $(VENV)/bin/semgrep
ADERYN := $(HOME)/.cyfrin/bin/aderyn

.PHONY: all build test clean deploy lint fmt audit security venv halmos test-fuzz test-invariant

# Test selection, shared verbatim with .github/workflows so a green CI and a
# green laptop mean the same thing. Fuzz runs only bite parameterized tests, so
# the unit suite is the fuzz suite. Invariants sit outside it because their
# harness file is not named *.t.sol.
FUZZ := src/test/**/*.t.sol
INVARIANT := src/test/Invariants/*.sol

# ═══════════════════════════════════════════════════════════════════
# Build & Test
# ═══════════════════════════════════════════════════════════════════

build:
	$(FORGE) build

clean:
	$(FORGE) clean
	rm -rf cache out

test:
	$(FORGE) test --summary

test-v:
	$(FORGE) test -vvvv

test-gas:
	$(FORGE) test --gas-report

test-fuzz:
	$(FORGE) test --match-path "$(FUZZ)" --fuzz-runs 1000

# Seeded so a reported counterexample reproduces.
test-invariant:
	$(FORGE) test --match-path "$(INVARIANT)" --fuzz-seed 42

coverage:
	$(FORGE) coverage --ir-minimum --report summary

coverage-lcov:
	$(FORGE) coverage --ir-minimum --report lcov --report-file lcov.info

# ═══════════════════════════════════════════════════════════════════
# Format & Lint
# ═══════════════════════════════════════════════════════════════════

fmt:
	$(FORGE) fmt

lint:
	$(FORGE) fmt --check
	$(FORGE) lint src/

# ═══════════════════════════════════════════════════════════════════
# Security (Python tools via uv virtualenv)
# ═══════════════════════════════════════════════════════════════════

venv: $(VENV)/.installed

$(VENV)/.installed:
	$(UV) venv $(VENV)
	$(UV) pip install --python $(VENV)/bin/python slither-analyzer semgrep halmos
	@touch $@

# Each scanner stops the build at the same threshold CI uses: slither at medium,
# semgrep at error, aderyn at high. A scanner that cannot fail reports nothing.
slither: venv
	$(SLITHER) src/ \
		--exclude-dependencies \
		--exclude-informational \
		--filter-paths "test/,mocks/,script/" \
		--fail-medium \
		--json slither-report.json
	@echo "Report: slither-report.json"

semgrep: venv
	$(SEMGREP) scan --config p/solidity --config p/smart-contracts \
		--severity ERROR --error \
		src/ --sarif -o semgrep-results.sarif
	@echo "Report: semgrep-results.sarif"

# Aderyn always exits 0, so the count in its own summary table is the verdict.
aderyn:
	@if [ ! -f "$(ADERYN)" ]; then \
		echo "Installing aderyn..."; \
		curl -L https://raw.githubusercontent.com/Cyfrin/aderyn/main/cyfrinup/install | bash; \
		$(HOME)/.cyfrin/bin/cyfrinup; \
	fi
	$(ADERYN) . --src src/ -x test,mocks --output aderyn-report.md
	@echo "Report: aderyn-report.md"
	@if grep -qE '^\| High \| [1-9]' aderyn-report.md; then \
		grep -E '^\| High \|' aderyn-report.md; \
		exit 1; \
	fi

# Run ALL security tools
security: slither semgrep aderyn
	@echo ""
	@echo "═══════════════════════════════════════════"
	@echo "  Security Audit Complete"
	@echo "═══════════════════════════════════════════"
	@echo "  Slither:  slither-report.json"
	@echo "  Semgrep:  semgrep-results.sarif"
	@echo "  Aderyn:   aderyn-report.md"
	@echo "═══════════════════════════════════════════"

# Full audit: lint + test + security
audit: lint test security
	@echo "Full audit complete."

# ═══════════════════════════════════════════════════════════════════
# Symbolic Execution (Halmos)
# ═══════════════════════════════════════════════════════════════════

HALMOS := $(VENV)/bin/halmos

# Unfiltered, halmos walks every contract the project compiles, lib/ included.
# The properties live in the four Halmos* contracts under src/test/halmos.
halmos: venv
	$(HALMOS) --match-contract '^Halmos' --function check \
		--solver-timeout-branching 10s --solver-timeout-assertion 300s

# ═══════════════════════════════════════════════════════════════════
# Deploy
# ═══════════════════════════════════════════════════════════════════

# One market per run. Supply DEBT_ADDRESS, UNDERLYING_ADDRESS, YIELD_ADDRESS
# and TOKEN_ADAPTER_ADDRESS for the market being brought up.
deploy-devnet:
	LIQUID_ENV=devnet $(FORGE) script script/DeployBrandL1.s.sol \
		--rpc-url https://api.lux-dev.network/v1/chain/C/rpc \
		--mnemonics "$$LUX_MNEMONIC" --broadcast -vvv

deploy-testnet:
	LIQUID_ENV=testnet $(FORGE) script script/DeployBrandL1.s.sol \
		--rpc-url https://api.lux-test.network/v1/chain/C/rpc \
		--mnemonics "$$LUX_MNEMONIC" --broadcast -vvv

deploy-mainnet:
	$(FORGE) script script/DeployMainnet.s.sol \
		--rpc-url https://api.lux.network/v1/chain/C/rpc \
		--mnemonics "$$LUX_MNEMONIC" --broadcast -vvv

deploy-all: deploy-devnet deploy-testnet deploy-mainnet

# ═══════════════════════════════════════════════════════════════════
# Utilities
# ═══════════════════════════════════════════════════════════════════

snapshot:
	$(FORGE) snapshot

sizes:
	$(FORGE) build --sizes

anvil:
	anvil --chain-id 96369 --mnemonic "$$LUX_MNEMONIC" --balance 10000000000

update:
	$(FORGE) update

install:
	$(FORGE) install

help:
	@echo "Build & Test:"
	@echo "  make build         Build contracts"
	@echo "  make test          Run all tests"
	@echo "  make test-v        Tests with full traces"
	@echo "  make test-fuzz     Fuzz tests (1000 runs)"
	@echo "  make test-invariant Invariant suite (seeded)"
	@echo "  make coverage      Coverage summary"
	@echo ""
	@echo "Security:"
	@echo "  make halmos        Symbolic execution over the check_ properties"
	@echo "  make security      Run slither + semgrep + aderyn"
	@echo "  make slither       Slither static analysis"
	@echo "  make semgrep       Semgrep SAST"
	@echo "  make aderyn        Aderyn Solidity analyzer"
	@echo "  make audit         Full: lint + test + security"
	@echo ""
	@echo "Deploy:"
	@echo "  make deploy-devnet   Deploy to devnet"
	@echo "  make deploy-testnet  Deploy to testnet"
	@echo "  make deploy-mainnet  Deploy to mainnet"
	@echo "  make deploy-all      Deploy to all networks"
	@echo ""
	@echo "Other:"
	@echo "  make fmt           Format code"
	@echo "  make lint          Check formatting + lint"
	@echo "  make sizes         Contract sizes"
	@echo "  make anvil         Start local node"
