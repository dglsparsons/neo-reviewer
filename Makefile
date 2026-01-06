.PHONY: test test-file test-watch lint clean install-deps

NVIM ?= nvim
PLENARY_DIR ?= $(HOME)/.local/share/nvim/site/pack/test/start/plenary.nvim

test:
	@$(NVIM) --headless -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory tests/plenary/ {minimal_init = 'tests/minimal_init.lua', sequential = true}"

test-file:
	@$(NVIM) --headless -u tests/minimal_init.lua \
		-c "PlenaryBustedFile $(FILE)"

install-deps:
	@mkdir -p $(dir $(PLENARY_DIR))
	@if [ ! -d "$(PLENARY_DIR)" ]; then \
		git clone --depth 1 https://github.com/nvim-lua/plenary.nvim $(PLENARY_DIR); \
	fi

clean:
	rm -rf $(PLENARY_DIR)
