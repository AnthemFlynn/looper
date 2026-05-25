# looper — universal build/install entry points.
#
#   make                build a debug binary into zig-out/bin/looper
#   make release        build a release binary into zig-out/bin/looper
#   make install        install to $(PREFIX)/bin/looper (default: ~/.local)
#                       pass PREFIX=/somewhere/else to override
#   make test           run the inline unit tests
#   make itest          run the manual integration script
#   make vN.M-acceptance run the milestone vN.M acceptance script
#                       (e.g. make v0.1-acceptance)
#   make acceptance     run every milestone acceptance script in order
#   make clean          remove build artifacts

PREFIX ?= $(HOME)/.local
BIN    := $(PREFIX)/bin/looper

.PHONY: build release install test itest clean acceptance \
        v0.1-acceptance v0.2-acceptance v0.3-acceptance v0.4-acceptance \
        v0.5-acceptance v0.6-acceptance v0.7-acceptance

build:
	zig build

release:
	zig build -Doptimize=ReleaseSafe

install:
	zig build -Doptimize=ReleaseSafe --prefix $(PREFIX)
	@echo
	@case ":$$PATH:" in \
	  *":$(PREFIX)/bin:"*) \
	    echo "✓ installed $(BIN)"; \
	    echo "  try:  looper --help" ;; \
	  *) \
	    echo "✓ installed $(BIN)"; \
	    echo; \
	    echo "  ⚠  $(PREFIX)/bin is NOT on your \$$PATH."; \
	    echo "  Add this line to your shell rc (~/.zshrc, ~/.bashrc):"; \
	    echo; \
	    echo "      export PATH=\"$(PREFIX)/bin:\$$PATH\""; \
	    echo; \
	    echo "  Or run it directly:  $(BIN) --help" ;; \
	esac

test:
	zig build test

itest: release
	LOOPER_BIN=zig-out/bin/looper ./scripts/integration-test.sh

v0.1-acceptance: release
	LOOPER_BIN=zig-out/bin/looper ./scripts/acceptance-v0.1.sh

v0.2-acceptance: release
	LOOPER_BIN=zig-out/bin/looper ./scripts/acceptance-v0.2.sh

v0.3-acceptance: release
	LOOPER_BIN=zig-out/bin/looper ./scripts/acceptance-v0.3.sh

v0.4-acceptance: release
	LOOPER_BIN=zig-out/bin/looper ./scripts/acceptance-v0.4.sh

v0.5-acceptance: release
	LOOPER_BIN=zig-out/bin/looper ./scripts/acceptance-v0.5.sh

v0.6-acceptance: release
	LOOPER_BIN=zig-out/bin/looper ./scripts/acceptance-v0.6.sh

v0.7-acceptance:
	./scripts/acceptance-v0.7.sh

acceptance: release
	LOOPER_BIN=zig-out/bin/looper ./scripts/acceptance-all.sh

clean:
	rm -rf zig-out .zig-cache
