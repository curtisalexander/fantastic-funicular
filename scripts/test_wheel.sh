#!/usr/bin/env bash
set -euo pipefail

# Local wheel build + install round-trip test
# Requires: zig, python3, uv

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DIST_DIR="$PROJECT_ROOT/dist"
PASS=0
FAIL=0

red()   { printf '\033[1;31m%s\033[0m\n' "$*"; }
green() { printf '\033[1;32m%s\033[0m\n' "$*"; }
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }

check() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        green "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        red "  FAIL: $desc"
        FAIL=$((FAIL + 1))
    fi
}

check_output() {
    local desc="$1"
    local expected="$2"
    shift 2
    local actual
    actual=$("$@" 2>&1) || true
    if echo "$actual" | grep -qF "$expected"; then
        green "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        red "  FAIL: $desc"
        red "    expected to contain: $expected"
        red "    got: $actual"
        FAIL=$((FAIL + 1))
    fi
}

# ── Preflight ────────────────────────────────────────────────────────────────

bold "Checking prerequisites..."
for cmd in zig python3 uv; do
    if ! command -v "$cmd" &>/dev/null; then
        red "Error: '$cmd' not found on PATH"
        exit 1
    fi
done
green "  zig $(zig version), python3 $(python3 --version | cut -d' ' -f2), uv $(uv --version | cut -d' ' -f2)"

# ── Step 1: Zig tests ───────────────────────────────────────────────────────

bold "Running Zig unit tests..."
check "zig build test" zig build test -Doptimize=Debug

# ── Step 2: Build binary ────────────────────────────────────────────────────

bold "Building Zig binary (ReleaseFast)..."
(cd "$PROJECT_ROOT" && zig build -Doptimize=ReleaseFast)
check "binary exists" test -x "$PROJECT_ROOT/zig-out/bin/aipipe"

# ── Step 3: Direct binary smoke tests ───────────────────────────────────────

bold "Testing binary directly..."
AIPIPE="$PROJECT_ROOT/zig-out/bin/aipipe"

check_output "hash stdin (xxhash)" "  -" \
    sh -c "echo hello | '$AIPIPE' hash"

check_output "hash stdin (sha256)" "  -" \
    sh -c "echo hello | '$AIPIPE' hash --sha256"

check_output "fence extract" 'print("hi")' \
    sh -c 'printf "text\n\`\`\`python\nprint(\"hi\")\n\`\`\`\n" | '"'$AIPIPE'"' fence'

check_output "fence wrap" '```python' \
    sh -c "echo 'x = 1' | '$AIPIPE' fence --wrap --lang python"

check_output "prompt with tokens" "tokens" \
    sh -c "'$AIPIPE' prompt -t '$PROJECT_ROOT/build.zig'"

check_output "--version" "aipipe 0.1.0" \
    "$AIPIPE" --version

# ── Step 4: Build wheel ─────────────────────────────────────────────────────

bold "Building wheel..."
rm -rf "$DIST_DIR"
python3 "$PROJECT_ROOT/scripts/build_wheel.py" --zig-binary "$AIPIPE"
WHEEL=$(ls "$DIST_DIR"/*.whl 2>/dev/null | head -1)
check "wheel file created" test -f "$WHEEL"

bold "  Wheel: $(basename "$WHEEL")"

# ── Step 5: Install wheel with uv and test ──────────────────────────────────

bold "Installing wheel with uv..."
# Use a temporary virtual env to avoid polluting the system
VENV_DIR=$(mktemp -d)
trap 'rm -rf "$VENV_DIR"' EXIT

uv venv "$VENV_DIR/venv"
# Install the wheel into the venv
VIRTUAL_ENV="$VENV_DIR/venv" uv pip install "$WHEEL"

# The binary should be in the venv's bin/ (scripts data installs there)
VENV_BIN="$VENV_DIR/venv/bin"
check "aipipe binary in venv" test -x "$VENV_BIN/aipipe"

bold "Testing installed binary via venv..."
check_output "installed: hash" "  -" \
    sh -c "echo hello | '$VENV_BIN/aipipe' hash"

check_output "installed: fence" 'x = 1' \
    sh -c "echo 'x = 1' | '$VENV_BIN/aipipe' fence --wrap --lang python"

check_output "installed: --version" "aipipe 0.1.0" \
    "$VENV_BIN/aipipe" --version

# Test python -m aipipe
check_output "installed: python -m aipipe" "USAGE" \
    "$VENV_BIN/python" -m aipipe help

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
bold "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    red "SOME TESTS FAILED"
    exit 1
else
    green "ALL TESTS PASSED"
fi
