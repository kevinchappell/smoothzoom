#!/bin/bash

# Development script for GNOME Extension on Wayland
# This script installs, enables, and reloads the extension without requiring logout

set -e

# Extension details
EXTENSION_UUID="smoothzoom@kevinchappell.github.io"
EXTENSION_DIR="$HOME/.local/share/gnome-shell/extensions/$EXTENSION_UUID"
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

paths_match() {
    [[ "$(cd "$1" 2>/dev/null && pwd -P)" == "$(cd "$2" 2>/dev/null && pwd -P)" ]]
}

# Function to check if GNOME Shell is running
check_gnome_shell() {
    if ! pgrep -x "gnome-shell" > /dev/null; then
        print_error "GNOME Shell is not running"
        exit 1
    fi
}

# GNOME 49+ removed `--nested`; the replacement is `--devkit` (a windowed dev
# shell that doesn't take over the seat). The old `Meta.restart()` and
# `ReloadExtension` paths are also disabled on Wayland, so the only way to
# pick up code changes is to relaunch the devkit shell (or log out/in for the
# real session).
start_nested_session() {
    print_status "Starting devkit GNOME Shell session for testing..."
    print_warning "Devkit Shell is only useful for limited UI smoke testing on Wayland"
    print_warning "It may not have access to the same microphone, clipboard, typing, or portal APIs as your real session"
    print_status "For normal development in your active Wayland session, prefer: $0 reload"
    print_status ""
    print_status "Steps to test the extension:"
    print_status "1. A new GNOME Shell window will open"
    print_status "2. Open a terminal inside the new session"
    print_status "3. Run: gnome-extensions enable $EXTENSION_UUID"
    print_status "4. Your extension should appear in the top bar"
    print_status "5. Close the devkit session when done testing"
    print_status ""
    print_status "Starting devkit session in 3 seconds..."
    sleep 3

    # Ensure extension is installed first
    if [ ! -d "$EXTENSION_DIR" ]; then
        print_status "Installing extension first..."
        install_extension
    fi

    print_status "Starting devkit GNOME Shell session..."
    if gnome-shell --help 2>&1 | grep -q -- '--devkit'; then
        dbus-run-session -- gnome-shell --devkit
    else
        dbus-run-session -- gnome-shell --nested --wayland
    fi
}

# Auto-enable the extension before launching the devkit shell. The extension
# enable state lives in dconf (per-user, shared with the main session), so
# enabling here also flips it on in the parent session — that's fine for a
# dev tool.
test_nested() {
    print_status "Testing extension in devkit GNOME Shell session..."
    print_warning "Devkit sessions are not a full substitute for real-session testing on Wayland"

    # Ensure extension is installed
    if [ ! -d "$EXTENSION_DIR" ]; then
        print_status "Installing extension first..."
        install_extension
    fi

    print_status "Enabling extension..."
    gnome-extensions enable "$EXTENSION_UUID" || true

    print_status "Starting devkit session with extension auto-enabled..."
    print_status ""

    if gnome-shell --help 2>&1 | grep -q -- '--devkit'; then
        dbus-run-session -- gnome-shell --devkit
    else
        dbus-run-session -- gnome-shell --nested --wayland
    fi
}

# Function to refresh GNOME Shell extension cache
refresh_cache() {
    print_status "Refreshing GNOME Shell extension cache..."

    # Try multiple methods to refresh the cache

    # Method 1: Use dbus to tell GNOME Shell to reload extensions
    if command -v busctl &> /dev/null; then
        print_status "Attempting to reload extensions via D-Bus..."
        busctl --user call org.gnome.Shell.Extensions /org/gnome/Shell/Extensions org.gnome.Shell.Extensions ReloadExtension s "$EXTENSION_UUID" 2>/dev/null || true
    fi

    # Method 2: Touch the extension directory to update mtime
    touch "$EXTENSION_DIR"

    # Method 3: Restart GNOME Shell if on X11
    if [ "$XDG_SESSION_TYPE" = "x11" ]; then
        print_status "Detected X11, attempting GNOME Shell restart..."
        busctl --user call org.gnome.Shell /org/gnome/Shell org.gnome.Shell Eval s 'Meta.restart("Restarting for extension reload...")' 2>/dev/null || true
    else
        print_warning "On Wayland, GNOME Shell cannot be reliably restarted in-place"
        print_status "This step only nudges extension discovery; use '$0 reload' for the real soft reload path"
        print_status "If a bug only clears after a fresh shell process, logout/login is still required"
    fi

    sleep 3
}

# Function to compile GSettings schema
compile_schema() {
    print_status "Compiling GSettings schema..."

    local schema_dir="$EXTENSION_DIR/schemas"
    local schema_file="$SOURCE_DIR/schemas/org.gnome.shell.extensions.smoothzoom.gschema.xml"
    local compiled_schema="$schema_dir/gschemas.compiled"

    # Check if schema file exists
    if [ ! -f "$schema_file" ]; then
        print_warning "No schema file found at $schema_file - skipping schema compilation"
        return 0
    fi

    # Check if glib-compile-schemas is available
    if ! command -v glib-compile-schemas &> /dev/null; then
        print_error "glib-compile-schemas not found. Install glib2-dev or libglib2.0-dev package."
        print_status "On Ubuntu/Debian: sudo apt install libglib2.0-dev"
        print_status "On Fedora/RHEL: sudo dnf install glib2-devel"
        return 1
    fi

    # Create schemas directory in extension dir
    mkdir -p "$schema_dir"

    local schema_source_dir
    schema_source_dir="$(dirname "$schema_file")"

    # Remove old compiled schema to ensure clean compilation
    [ -f "$compiled_schema" ] && rm -f "$compiled_schema"

    # Validate schema XML syntax before copying
    if command -v xmllint &> /dev/null; then
        print_status "Validating schema XML syntax..."
        if ! xmllint --noout "$schema_file" 2>/dev/null; then
            print_error "Schema file has invalid XML syntax"
            return 1
        fi
        print_status "Schema XML syntax is valid"
    else
        print_warning "xmllint not found - skipping XML validation"
    fi

    if paths_match "$schema_source_dir" "$schema_dir"; then
        print_status "Schema source and target are the same directory; compiling in place"
    else
        # Copy schema file with error checking
        if ! cp "$schema_file" "$schema_dir/"; then
            print_error "Failed to copy schema file"
            return 1
        fi
        print_status "Copied schema file to extension directory"
    fi

    # Compile the schema with detailed error output
    print_status "Compiling schema with glib-compile-schemas..."
    local compile_output
    if compile_output=$(glib-compile-schemas "$schema_dir" 2>&1); then
        if [ -f "$compiled_schema" ]; then
            print_success "Schema compiled successfully"
            print_status "Generated: $(basename "$compiled_schema")"

            # Show schema file size for verification
            local schema_size=$(stat -c%s "$compiled_schema" 2>/dev/null || echo "unknown")
            print_status "Compiled schema size: ${schema_size} bytes"
        else
            print_warning "Schema compilation appeared successful but no compiled schema found"
            return 1
        fi
    else
        print_error "Failed to compile schema:"
        echo "$compile_output" | while IFS= read -r line; do
            print_error "  $line"
        done
        return 1
    fi

    # Verify the compiled schema is readable
    if [ -r "$compiled_schema" ]; then
        print_status "Compiled schema is readable and ready for use"
    else
        print_warning "Compiled schema exists but may not be readable"
        return 1
    fi

    return 0
}

# Function to install/update the extension
install_extension() {
    print_status "Installing/updating extension..."

    # Define required and optional files/directories to copy
    local required_files=("metadata.json" "extension.js" "zoomer.js")
    local optional_files=("prefs.js" "README.md" "CHANGELOG.md" "LICENSE")
    local optional_dirs=("icons" "locale")

    # Check for required files first
    for file in "${required_files[@]}"; do
        if [ ! -f "$SOURCE_DIR/$file" ]; then
            print_error "Required file missing: $file"
            return 1
        fi
    done

    # Create extension directory if it doesn't exist
    mkdir -p "$EXTENSION_DIR"

    if paths_match "$SOURCE_DIR" "$EXTENSION_DIR"; then
        print_status "Source and extension directories are the same; skipping cleanup and file copy"
    else
        # Remove old files to ensure clean install (but preserve schemas if they exist)
        print_status "Cleaning old extension files..."
        find "$EXTENSION_DIR" -type f \( -name "*.js" -o -name "*.css" -o -name "*.json" \) -not -path "*/schemas/*" -delete 2>/dev/null || true

        # Copy required files with error checking
        for file in "${required_files[@]}"; do
            if ! cp "$SOURCE_DIR/$file" "$EXTENSION_DIR/"; then
                print_error "Failed to copy $file"
                return 1
            fi
            print_status "Copied $file"
        done

        # Copy optional files if they exist
        for file in "${optional_files[@]}"; do
            if [ -f "$SOURCE_DIR/$file" ]; then
                print_status "Copying optional file: $file"
                cp "$SOURCE_DIR/$file" "$EXTENSION_DIR/"
            fi
        done

        # Copy optional directories if they exist
        for dir in "${optional_dirs[@]}"; do
            if [ -d "$SOURCE_DIR/$dir" ]; then
                print_status "Copying directory: $dir"
                cp -r "$SOURCE_DIR/$dir" "$EXTENSION_DIR/"
            fi
        done
    fi

    # Compile and copy schema
    if ! compile_schema; then
        print_warning "Schema compilation failed, but continuing..."
    fi

    # Set proper permissions
    print_status "Setting proper permissions..."
    find "$EXTENSION_DIR" -type f -exec chmod 644 {} \; 2>/dev/null || true
    find "$EXTENSION_DIR" -type d -exec chmod 755 {} \; 2>/dev/null || true

    # Ensure proper ownership
    if ! chown -R "$USER:$USER" "$EXTENSION_DIR" 2>/dev/null; then
        print_warning "Could not set ownership (may require sudo)"
    fi

    # Validate critical files
    print_status "Validating installation..."

    # Validate metadata.json
    if ! python3 -m json.tool "$EXTENSION_DIR/metadata.json" > /dev/null 2>&1; then
        print_error "Invalid JSON in metadata.json"
        return 1
    fi

    # Basic JavaScript syntax check (ESM) if node is available.
    # GJS extension modules use ESM `import` syntax, so we pipe through node
    # with --input-type=module instead of `node -c` (which treats files as CJS).
    if command -v node &> /dev/null; then
        if ! node --check --input-type=module < "$EXTENSION_DIR/extension.js" 2>/dev/null; then
            print_error "JavaScript syntax error in extension.js"
            node --check --input-type=module < "$EXTENSION_DIR/extension.js" || true
            return 1
        fi

        if [ -f "$EXTENSION_DIR/zoomer.js" ] && ! node --check --input-type=module < "$EXTENSION_DIR/zoomer.js" 2>/dev/null; then
            print_error "JavaScript syntax error in zoomer.js"
            node --check --input-type=module < "$EXTENSION_DIR/zoomer.js" || true
            return 1
        fi

        if [ -f "$EXTENSION_DIR/prefs.js" ] && ! node --check --input-type=module < "$EXTENSION_DIR/prefs.js" 2>/dev/null; then
            print_error "JavaScript syntax error in prefs.js"
            node --check --input-type=module < "$EXTENSION_DIR/prefs.js" || true
            return 1
        fi
    fi

    # Verify UUID matches in metadata.json
    local metadata_uuid=$(python3 -c "import json, sys; print(json.load(open('$EXTENSION_DIR/metadata.json'))['uuid'])" 2>/dev/null)
    if [ "$metadata_uuid" != "$EXTENSION_UUID" ]; then
        print_error "UUID mismatch: metadata.json has '$metadata_uuid' but expected '$EXTENSION_UUID'"
        return 1
    fi

    print_success "Extension files copied and validated in $EXTENSION_DIR"

    # Show what was installed
    print_status "Installed files:"
    find "$EXTENSION_DIR" -type f -printf "  %P\n" 2>/dev/null | sort || ls -la "$EXTENSION_DIR"
}

# Function to enable the extension
enable_extension() {
    print_status "Enabling extension..."

    # Wait a moment for GNOME Shell to detect the extension
    sleep 2

    # Check if extension is recognized first
    if ! gnome-extensions list | grep -q "$EXTENSION_UUID"; then
        print_error "Extension not detected by GNOME Shell. Checking for issues..."

        # Check if extension directory exists
        if [ ! -d "$EXTENSION_DIR" ]; then
            print_error "Extension directory does not exist: $EXTENSION_DIR"
            return 1
        fi

        # Check required files
        for file in metadata.json extension.js; do
            if [ ! -f "$EXTENSION_DIR/$file" ]; then
                print_error "Missing required file: $file"
                return 1
            fi
        done

        # Check metadata.json syntax
        if ! python3 -m json.tool "$EXTENSION_DIR/metadata.json" > /dev/null 2>&1; then
            print_error "Invalid JSON syntax in metadata.json"
            return 1
        fi

        print_error "Extension files appear correct but GNOME Shell isn't detecting it"
        print_status "Try '$0 reload' first; if GNOME Shell still does not detect it, a full session restart may be required"
        return 1
    fi

    if gnome-extensions enable "$EXTENSION_UUID" 2>/dev/null; then
        print_success "Extension enabled"
        return 0
    else
        print_warning "Extension might already be enabled or there was an issue"
        return 1
    fi
}

# Function to disable the extension
disable_extension() {
    print_status "Disabling extension..."

    if gnome-extensions disable "$EXTENSION_UUID" 2>/dev/null; then
        print_success "Extension disabled"
        return 0
    else
        print_warning "Extension might already be disabled"
        return 1
    fi
}

# Function to reload the extension (disable then enable)
reload_extension() {
    print_status "Reloading extension..."

    # Check if extension exists first
    if ! gnome-extensions list | grep -q "$EXTENSION_UUID"; then
        print_error "Extension not found in GNOME Shell extensions list"
        print_status "Trying to install and enable instead..."
        enable_extension
        return $?
    fi

    # Disable first (don't fail if already disabled)
    gnome-extensions disable "$EXTENSION_UUID" 2>/dev/null || true
    sleep 1

    # Enable again
    if gnome-extensions enable "$EXTENSION_UUID" 2>/dev/null; then
        print_success "Extension reloaded successfully"
        return 0
    else
        print_error "Failed to reload extension"
        print_status "Extension info:"
        gnome-extensions info "$EXTENSION_UUID" 2>/dev/null || print_error "Could not get extension info"
        return 1
    fi
}

# Function to check extension status
check_status() {
    print_status "Checking extension status..."

    if gnome-extensions list | grep -q "$EXTENSION_UUID"; then
        local status=$(gnome-extensions info "$EXTENSION_UUID" | grep "State:" | awk '{print $2}')
        print_status "Extension found with state: $status"

        if [ "$status" = "ENABLED" ]; then
            print_success "Extension is currently enabled"
        else
            print_warning "Extension is installed but not enabled"
        fi
    else
        print_warning "Extension not found in installed extensions"
    fi
}

# Function to watch for file changes (requires inotify-tools)
watch_changes() {
    if ! command -v inotifywait &> /dev/null; then
        print_error "inotifywait not found. Install inotify-tools package for file watching."
        print_status "On Ubuntu/Debian: sudo apt install inotify-tools"
        exit 1
    fi

    print_status "Watching for changes in $SOURCE_DIR..."
    print_status "Press Ctrl+C to stop watching"

    # Build list of files to watch
    local watch_files=(
        "$SOURCE_DIR/extension.js"
        "$SOURCE_DIR/zoomer.js"
        "$SOURCE_DIR/metadata.json"
    )

    # Add optional files if they exist
    [ -f "$SOURCE_DIR/prefs.js" ] && watch_files+=("$SOURCE_DIR/prefs.js")
    [ -f "$SOURCE_DIR/schemas/org.gnome.shell.extensions.smoothzoom.gschema.xml" ] && watch_files+=("$SOURCE_DIR/schemas/org.gnome.shell.extensions.smoothzoom.gschema.xml")

    while true; do
        inotifywait -e modify,move,create,delete "${watch_files[@]}" 2>/dev/null

        print_status "File change detected, reloading extension..."
        install_extension
        reload_extension
        echo ""
    done
}

# Function to show logs
show_logs() {
    print_status "Showing GNOME Shell logs (press Ctrl+C to stop)..."
    journalctl -f -o cat GNOME_SHELL_EXTENSION_UUID="$EXTENSION_UUID" 2>/dev/null || \
    journalctl -f -o cat /usr/bin/gnome-shell 2>/dev/null || \
    print_warning "Unable to show logs. Try: journalctl -f /usr/bin/gnome-shell"
}

# Function to clean/uninstall the extension
uninstall_extension() {
    print_status "Uninstalling extension..."

    # Disable first
    gnome-extensions disable "$EXTENSION_UUID" 2>/dev/null || true

    # Remove directory
    if [ -d "$EXTENSION_DIR" ]; then
        rm -rf "$EXTENSION_DIR"
        print_success "Extension uninstalled successfully"
    else
        print_warning "Extension directory not found"
    fi
}

# Main script logic
case "${1:-install}" in
    "install"|"i")
        check_gnome_shell
        disable_extension
        install_extension
        refresh_cache
        enable_extension
        check_status
        ;;

    "reload"|"r")
        check_gnome_shell
        install_extension
        refresh_cache
        reload_extension
        ;;

    "refresh"|"rf")
        refresh_cache
        check_status
        ;;

    "enable"|"e")
        enable_extension
        check_status
        ;;

    "disable"|"d")
        disable_extension
        ;;

    "status"|"s")
        check_status
        ;;

    "watch"|"w")
        check_gnome_shell
        install_extension
        enable_extension
        watch_changes
        ;;

    "nested"|"n")
        check_gnome_shell
        start_nested_session
        ;;

    "test"|"t")
        check_gnome_shell
        test_nested
        ;;

    "prefs"|"p")
        check_gnome_shell
        install_extension
        print_status "Opening extension preferences..."
        if gnome-extensions prefs "$EXTENSION_UUID" 2>/dev/null; then
            print_success "Preferences opened"
        else
            print_error "Failed to open preferences. Extension might not be installed or enabled."
            print_status "Trying to enable extension first..."
            enable_extension
            sleep 2
            gnome-extensions prefs "$EXTENSION_UUID"
        fi
        ;;

    "logs"|"l")
        show_logs
        ;;

    "debug"|"db")
        print_status "Extension Debug Information"
        echo "=================================="
        echo "Extension UUID: $EXTENSION_UUID"
        echo "Extension Directory: $EXTENSION_DIR"
        echo "Source Directory: $SOURCE_DIR"
        echo ""
        print_status "Checking if extension directory exists..."
        if [ -d "$EXTENSION_DIR" ]; then
            print_success "Extension directory exists"
            echo "Contents:"
            ls -la "$EXTENSION_DIR"
        else
            print_error "Extension directory does not exist"
        fi
        echo ""
        print_status "Checking if extension is in GNOME Shell list..."
        if gnome-extensions list | grep -q "$EXTENSION_UUID"; then
            print_success "Extension found in GNOME Shell"
            gnome-extensions info "$EXTENSION_UUID"
        else
            print_warning "Extension NOT found in GNOME Shell"
        fi
        echo ""
        print_status "Checking metadata.json syntax..."
        if [ -f "$EXTENSION_DIR/metadata.json" ]; then
            if python3 -m json.tool "$EXTENSION_DIR/metadata.json" > /dev/null 2>&1; then
                print_success "metadata.json syntax is valid"
            else
                print_error "metadata.json has syntax errors"
            fi
        else
            print_error "metadata.json not found"
        fi
        echo ""
        print_status "Checking JavaScript syntax..."
        check_esm() {
            local label="$1" path="$2"
            if [ ! -f "$path" ]; then
                print_error "$label not found"
                return 1
            fi
            if node --check --input-type=module < "$path" 2>/dev/null; then
                print_success "$label syntax is valid"
            else
                print_error "$label has syntax errors"
                node --check --input-type=module < "$path" || true
            fi
        }
        check_esm "extension.js" "$EXTENSION_DIR/extension.js"
        check_esm "zoomer.js"    "$EXTENSION_DIR/zoomer.js"
        echo ""
        print_status "Checking preferences file..."
        if [ -f "$EXTENSION_DIR/prefs.js" ]; then
            check_esm "prefs.js" "$EXTENSION_DIR/prefs.js"
        else
            print_warning "prefs.js not found (optional)"
        fi
        echo ""
        print_status "Checking GSettings schema..."
        if [ -f "$EXTENSION_DIR/schemas/gschemas.compiled" ]; then
            print_success "GSettings schema is compiled"
        elif [ -f "$SOURCE_DIR/schemas/org.gnome.shell.extensions.smoothzoom.gschema.xml" ]; then
            print_warning "Schema file exists but not compiled"
        else
            print_warning "No GSettings schema found (optional)"
        fi
        ;;

    "uninstall"|"u")
        uninstall_extension
        ;;

    "help"|"h"|*)
        echo "GNOME Extension Development Script"
        echo ""
        echo "Usage: $0 [command]"
        echo ""
        echo "Commands:"
        echo "  install, i    Install and enable the extension (default)"
        echo "  reload, r     Reinstall and soft-reload the extension in the current session"
        echo "  refresh, rf   Nudge GNOME Shell cache/mtime detection"
        echo "  enable, e     Enable the extension"
        echo "  disable, d    Disable the extension"
        echo "  status, s     Check extension status"
        echo "  watch, w      Watch for file changes and auto-reload in the current session"
        echo "  nested, n     Start devkit GNOME Shell for limited smoke testing"
        echo "  test, t       Auto-enable extension in a devkit smoke-test session"
        echo "  prefs, p      Open extension preferences dialog"
        echo "  logs, l       Show GNOME Shell logs"
        echo "  debug, db     Show detailed debug information"
        echo "  uninstall, u  Uninstall the extension"
        echo "  help, h       Show this help message"
        echo ""
        echo "Examples:"
        echo "  $0 install    # Install and enable extension"
        echo "  $0 reload     # Preferred Wayland workflow for code changes"
        echo "  $0 nested     # Run a limited devkit-session smoke test"
        echo "  $0 test       # Auto-test in a devkit smoke-test session"
        echo "  $0 prefs      # Open preferences (zoom level, follow smoothing, hotkeys)"
        echo "  $0 watch      # Auto-reload on file changes in the active session"
        echo "  $0 logs       # Monitor logs while developing"
        ;;
esac
