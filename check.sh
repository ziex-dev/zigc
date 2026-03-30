#!/bin/bash
set -euo pipefail

# Smoke-tests @zigc/* packages.
# In CI (default): tests binaries directly from the workspace — no registry needed.
# With --registry: publishes to a local Verdaccio registry and tests via npx.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REGISTRY="http://localhost:4873"
PASSED=0
FAILED=0
USE_REGISTRY=false

# Parse flags
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --registry) USE_REGISTRY=true; shift ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

VERSION="${1:-}"
ZIG_VERSION="${2:-}"

cleanup() {
  if [ -n "${VERDACCIO_PID:-}" ]; then
    kill "$VERDACCIO_PID" 2>/dev/null || true
    wait "$VERDACCIO_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# Resolve expected npm version
if [ -z "$VERSION" ]; then
  VERSION=$(node -p "require('$SCRIPT_DIR/package.json').version")
fi

# ZIG_VERSION is what `zig version` prints — may differ from npm version when
# npm_version is overridden (e.g. 0.16.0-test.0 vs 0.16.0-dev.3039+b490412cd)
if [ -z "$ZIG_VERSION" ]; then
  ZIG_VERSION="$VERSION"
fi

echo "==> Checking packages at npm version $VERSION (zig version: $ZIG_VERSION)"

pass() { PASSED=$((PASSED + 1)); echo "  PASS: $1"; }
fail() { FAILED=$((FAILED + 1)); echo "  FAIL: $1"; }

if [ "$USE_REGISTRY" = true ]; then
  # --- Registry mode: publish to Verdaccio and test via npx ---
  if ! curl -sf "$REGISTRY/-/ping" > /dev/null 2>&1; then
    if [ -n "${CI:-}" ]; then
      echo "==> Starting Verdaccio in CI..."
      npm install -g verdaccio --registry https://registry.npmjs.org
    else
      echo "==> Starting local Verdaccio registry..."
      npx --yes --registry https://registry.npmjs.org verdaccio --version > /dev/null
    fi
    verdaccio --config "$SCRIPT_DIR/verdaccio.yaml" --listen 4873 &
    VERDACCIO_PID=$!

    for i in $(seq 1 120); do
      if curl -sf "$REGISTRY/-/ping" > /dev/null 2>&1; then
        echo "==> Verdaccio is up."
        break
      fi
      sleep 0.5
    done

    if ! curl -sf "$REGISTRY/-/ping" > /dev/null 2>&1; then
      echo "ERROR: Verdaccio failed to start within 60s" >&2
      exit 1
    fi
  else
    echo "==> Verdaccio already running, skipping startup."
  fi

  echo "==> Publishing @zigc/* workspaces to local registry..."
  cd "$SCRIPT_DIR"
  npm publish --workspaces --registry "$REGISTRY" --tag dev \
    "--//localhost:4873/:_authToken=local-dev-token" 2>&1

  CHECK_TMP=$(mktemp -d)
  trap 'rm -rf "$CHECK_TMP"; cleanup' EXIT
  cd "$CHECK_TMP"

  echo ""
  echo "Running checks (registry mode)..."

  echo ""
  CLI_OUTPUT=$(npx --yes --registry "$REGISTRY" @zigc/cli@dev version 2>&1) || true
  if echo "$CLI_OUTPUT" | grep -qF "$ZIG_VERSION"; then
    pass "npx @zigc/cli version > $ZIG_VERSION"
  else
    fail "npx @zigc/cli version expected '$ZIG_VERSION', got: $CLI_OUTPUT"
  fi

  echo ""
  INIT_OUTPUT=$(npx --yes --registry "$REGISTRY" @zigc/cli@dev init 2>&1) || true
  if [ -n "$INIT_OUTPUT" ]; then
    pass "npx @zigc/cli init produces output"
  else
    fail "npx @zigc/cli init produced no output"
  fi

  echo ""
  BUILD_OUTPUT=$(npx --yes --registry "$REGISTRY" @zigc/cli@dev build run 2>&1) || true
  if [ -n "$BUILD_OUTPUT" ]; then
    pass "npx @zigc/cli build run produces output"
  else
    fail "npx @zigc/cli build run produced no output"
  fi

  if command -v bunx &> /dev/null; then
    echo ""
    BUNX_OUTPUT=$(timeout 60 env BUN_CONFIG_REGISTRY="$REGISTRY" BUN_CONFIG_IGNORE_SCRIPTS=true bunx --verbose @zigc/cli@dev version 2>&1) || true
    if echo "$BUNX_OUTPUT" | grep -qF "$ZIG_VERSION"; then
      pass "bunx @zigc/cli version > $ZIG_VERSION"
    else
      fail "bunx @zigc/cli version expected '$ZIG_VERSION', got: $BUNX_OUTPUT"
    fi
  fi

else
  # --- Direct mode: test binaries from the workspace (fast, no registry) ---
  echo ""
  echo "Running checks (direct mode)..."

  # Resolve the platform binary from the workspace
  case "$(uname -s)-$(uname -m)" in
    Darwin-arm64)  ZIG_BIN="$SCRIPT_DIR/darwin-arm64/bin/zig" ;;
    Darwin-x86_64) ZIG_BIN="$SCRIPT_DIR/darwin-x64/bin/zig" ;;
    Linux-x86_64)  ZIG_BIN="$SCRIPT_DIR/linux-x64/bin/zig" ;;
    Linux-aarch64) ZIG_BIN="$SCRIPT_DIR/linux-arm64/bin/zig" ;;
    MINGW*|MSYS*|CYGWIN*)
      if [ "$(uname -m)" = "x86_64" ]; then
        ZIG_BIN="$SCRIPT_DIR/win32-x64/bin/zig.exe"
      else
        ZIG_BIN="$SCRIPT_DIR/win32-arm64/bin/zig.exe"
      fi ;;
    *) echo "Unsupported platform: $(uname -s)-$(uname -m)" >&2; exit 1 ;;
  esac

  if [ ! -f "$ZIG_BIN" ]; then
    echo "Binary not found: $ZIG_BIN" >&2
    exit 1
  fi

  CHECK_TMP=$(mktemp -d)
  cd "$CHECK_TMP"

  echo ""
  CLI_OUTPUT=$("$ZIG_BIN" version 2>&1) || true
  if echo "$CLI_OUTPUT" | grep -qF "$ZIG_VERSION"; then
    pass "zig version > $ZIG_VERSION"
  else
    fail "zig version expected '$ZIG_VERSION', got: $CLI_OUTPUT"
  fi

  echo ""
  INIT_OUTPUT=$("$ZIG_BIN" init 2>&1) || true
  if [ -n "$INIT_OUTPUT" ]; then
    pass "zig init produces output"
  else
    fail "zig init produced no output"
  fi

  echo ""
  BUILD_OUTPUT=$("$ZIG_BIN" build run 2>&1) || true
  if [ -n "$BUILD_OUTPUT" ]; then
    pass "zig build run produces output"
  else
    fail "zig build run produced no output"
  fi
fi

# --- Summary ---
echo ""
echo "  Results: $PASSED passed, $FAILED failed"

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
