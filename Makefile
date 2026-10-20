.PHONY: test install icons smoke

# unit tests for the pure modules, under the plain steel CLI
test:
	@cd tests && for t in *-test.scm; do echo "== $$t"; steel $$t || exit 1; done

# install this checkout as the ideish cog and build libideish
install:
	forge install --force

# regenerate icons/catalog.scm from nvim-web-devicons
icons:
	python3 tools/gen-icons.py

# start Helix with dev/init.scm in tmux and check that ideish draws
smoke:
	./dev/test.sh
