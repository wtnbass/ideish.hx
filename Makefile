STEEL_HOME ?= $(HOME)/.local/share/steel
TARGET_DIR := $(STEEL_HOME)/target/ideish
DYLIB := $(if $(filter Darwin,$(shell uname -s)),libideish.dylib,libideish.so)

.PHONY: test native icons smoke

# unit tests for the pure modules, under the plain steel CLI
test:
	@cd tests && for t in *-test.scm; do echo "== $$t"; steel $$t || exit 1; done

# build libideish and put it where Helix loads dylibs from
native:
	cd native && CARGO_TARGET_DIR=$(TARGET_DIR) cargo build --release
	mkdir -p $(STEEL_HOME)/native
	cp $(TARGET_DIR)/release/$(DYLIB) $(STEEL_HOME)/native/$(DYLIB)

# regenerate icons/catalog.scm from nvim-web-devicons
icons:
	python3 tools/gen-icons.py

# start Helix with dev/init.scm in tmux and check that ideish draws
smoke:
	./dev/test.sh
