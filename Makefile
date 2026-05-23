# looper — universal build/install entry points.
#
#   make           build a debug binary into zig-out/bin/looper
#   make release   build a release binary into zig-out/bin/looper
#   make install   install to $(PREFIX)/bin/looper (default: ~/.local)
#                  pass PREFIX=/somewhere/else to override
#   make test      run the inline unit tests
#   make itest     run the manual integration script
#   make clean     remove build artifacts

PREFIX ?= $(HOME)/.local
BIN    := $(PREFIX)/bin/looper

.PHONY: build release install test itest clean

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

clean:
	rm -rf zig-out .zig-cache
