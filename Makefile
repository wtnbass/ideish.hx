.PHONY: test install icons smoke

# unit tests for the pure modules, under the plain steel CLI
test:
	@cd tests && for t in *-test.scm; do echo "== $$t"; steel $$t || exit 1; done

# install this checkout as the ideish cog and build libideish.
# TERMINAL=1 adds the terminal pane, which needs the Zig pinned in mise.toml
install:
	$(if $(TERMINAL),RUSTFLAGS="--cfg ideish_terminal" ZIG="$$(mise which zig 2>/dev/null || command -v zig)") forge install --force

# regenerate icons/catalog.scm from nvim-web-devicons
icons:
	python3 tools/gen-icons.py

# start Helix with dev/init.scm in tmux and check that ideish draws
smoke:
	./dev/test.sh
