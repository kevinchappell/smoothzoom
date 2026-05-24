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

pack: schemas
	@rm -f $(UUID).zip
	@zip -r $(UUID).zip \
		extension.js \
		zoomer.js \
		prefs.js \
		metadata.json \
		schemas/org.gnome.shell.extensions.smoothzoom.gschema.xml \
		schemas/gschemas.compiled \
		README.md \
		$$( [ -f LICENSE ] && echo LICENSE )

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
