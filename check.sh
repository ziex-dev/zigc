#!/bin/bash
set -euo pipefail

# Smoke-tests @zigc/* packages by publishing to a local Verdaccio registry
# and verifying that the CLI binary works.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REGISTRY="http://localhost:4873"
PASSED=0
FAILED=0
VERSION="${1:-}"
ZIG_VERSION="${2:-}"
CHECK_TMP=$(mktemp -d)

cleanup() {
  if [ -n "${VERDACCIO_PID:-}" ]; then
    kill "$VERDACCIO_PID" 2>/dev/null || true
    wait "$VERDACCIO_PID" 2>/dev/null || true
  fi
  rm -rf "$CHECK_TMP"
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

# Start Verdaccio only if not already running (install with real registry, before overriding)
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

  # Wait for Verdaccio to be ready (up to 60s)
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

# Publish all workspace packages to local registry
echo "==> Publishing @zigc/* workspaces to local registry..."
cd "$SCRIPT_DIR"
npm publish --workspaces --registry "$REGISTRY" --tag dev 2>&1

cd "$CHECK_TMP"

pass() { PASSED=$((PASSED + 1)); echo "  PASS: $1"; }
fail() { FAILED=$((FAILED + 1)); echo "  FAIL: $1"; }

# --- Tests ---

echo ""
echo "Running checks..."

# Check @zigc/cli version command (binary outputs the real Zig version, not npm version)
echo ""
CLI_OUTPUT=$(npx --yes --registry "$REGISTRY" @zigc/cli@dev version 2>&1) || true
if echo "$CLI_OUTPUT" | grep -qF "$ZIG_VERSION"; then
  pass "npx @zigc/cli version > $ZIG_VERSION"
else
  fail "npx @zigc/cli version expected '$ZIG_VERSION', got: $CLI_OUTPUT"
fi

# Check @zigc/cli init command
echo ""
INIT_OUTPUT=$(npx --yes --registry "$REGISTRY" @zigc/cli@dev init 2>&1) || true
if [ -n "$INIT_OUTPUT" ]; then
  pass "npx @zigc/cli init produces output"
else
  fail "npx @zigc/cli init produced no output"
fi

# Check @zigc/cli build command
echo ""
BUILD_OUTPUT=$(npx --yes --registry "$REGISTRY" @zigc/cli@dev build 2>&1) || true
if [ -n "$BUILD_OUTPUT" ]; then
  pass "npx @zigc/cli build produces output"
else
  fail "npx @zigc/cli build produced no output"
fi

# Check bunx compatibility
if command -v bunx &> /dev/null; then
  echo ""
  BUNX_OUTPUT=$(timeout 60 env BUN_CONFIG_REGISTRY="$REGISTRY" BUN_CONFIG_IGNORE_SCRIPTS=true bunx --verbose @zigc/cli@dev version 2>&1) || true
  if echo "$BUNX_OUTPUT" | grep -qF "$ZIG_VERSION"; then
    pass "bunx @zigc/cli version > $ZIG_VERSION"
  else
    fail "bunx @zigc/cli version expected '$ZIG_VERSION', got: $BUNX_OUTPUT"
  fi
fi

# --- Summary ---
echo ""
echo "  Results: $PASSED passed, $FAILED failed"

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
