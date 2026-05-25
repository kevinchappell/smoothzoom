# Makefile for GNOME Extension Development

UUID = smoothzoom@kevinchappell.github.io

.PHONY: install reload enable disable status watch nested test logs uninstall clean pack schemas help

# Default target
install:
	@./dev.sh install

# Development targets
reload:
	@./dev.sh reload

enable:
	@./dev.sh enable

disable:
	@./dev.sh disable

status:
	@./dev.sh status

watch:
	@./dev.sh watch

nested:
	@./dev.sh nested

test:
	@./dev.sh test

logs:
	@./dev.sh logs

# Build targets
schemas:
	glib-compile-schemas schemas/

pack:
	@# Build a zip suitable for upload to https://extensions.gnome.org/upload/.
	@# EGO compiles GSettings schemas server-side, so gschemas.compiled is
	@# intentionally NOT included — only the source XML is shipped. All
	@# files must sit at the zip root (no parent directory), which `zip`
	@# already does when invoked from the extension directory.
	@rm -f $(UUID).zip
	@# Validate schema XML before packaging.
	@if command -v xmllint >/dev/null 2>&1; then \
		xmllint --noout schemas/org.gnome.shell.extensions.smoothzoom.gschema.xml \
			|| { echo "Schema XML failed validation"; exit 1; }; \
	fi
	@zip -q $(UUID).zip \
		metadata.json \
		extension.js \
		zoomer.js \
		prefs.js \
		schemas/org.gnome.shell.extensions.smoothzoom.gschema.xml \
		README.md \
		LICENSE
	@echo "Built $(UUID).zip:"
	@unzip -l $(UUID).zip

# Cleanup targets
uninstall:
	@./dev.sh uninstall

clean: uninstall

# Help
help:
	@./dev.sh help
	@echo ""
	@echo "Makefile targets:"
	@echo "  make install    # Install and enable extension"
	@echo "  make reload     # Quick reload during development"
	@echo "  make nested     # Test in nested GNOME Shell (recommended for Wayland)"
	@echo "  make test       # Auto-test in nested session"
	@echo "  make watch      # Auto-reload on file changes"
	@echo "  make logs       # Show GNOME Shell logs"
	@echo "  make status     # Check extension status"
	@echo "  make uninstall  # Remove extension"
