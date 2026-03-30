#!/bin/bash
set -euo pipefail

# Downloads Zig compiler binaries for all platforms.
# Reads version from package.json.
# Places lib/ in the shared @zigc/lib package (identical across platforms).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
CACHE_DIR="$SCRIPT_DIR/.cache"

# Zig signing public key (from https://ziglang.org/download/)
ZIG_PUBKEY="RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U"

# Read version and resolve full Zig version in one node call
read -r ZIG_VER ZIG_FULL_VER_RAW <<< "$(node -e "
  const p = require('$SCRIPT_DIR/package.json').version;
  let full = p;
  const upstream = process.env.ZIG_UPSTREAM_VERSION || '';
  if (upstream) {
    full = upstream;
  } else if (p.includes('-dev')) {
    try { full = require('$SCRIPT_DIR/index.json').master.version; } catch {}
  }
  process.stdout.write(p + ' ' + full);
")"
ZIG_FULL_VER="${ZIG_UPSTREAM_VERSION:-$ZIG_FULL_VER_RAW}"

# Update version in all workspace package.json files (in parallel)
echo "Updating package versions to $ZIG_VER..."
pids=()
for pkg in lib cli darwin-arm64 darwin-x64 linux-x64 linux-arm64 win32-x64 win32-arm64; do
  pkg_json="$SCRIPT_DIR/$pkg/package.json"
  [ -f "$pkg_json" ] || continue
  node -e "
    const fs = require('fs');
    const p = JSON.parse(fs.readFileSync('$pkg_json', 'utf8'));
    p.version = '$ZIG_VER';
    for (const key of ['dependencies', 'optionalDependencies']) {
      if (!p[key]) continue;
      for (const dep of Object.keys(p[key])) {
        if (dep.startsWith('@zigc/')) p[key][dep] = '$ZIG_VER';
      }
    }
    fs.writeFileSync('$pkg_json', JSON.stringify(p, null, 2) + '\n');
  " &
  pids+=($!)
done
for pid in "${pids[@]}"; do wait "$pid"; done

# --version: only sync package versions, skip downloads
if [[ "${1:-}" == "--version" ]]; then
  echo "Done."
  exit 0
fi

# Dev builds use /builds/, releases use /download/<ver>/
if [[ "$ZIG_FULL_VER" == *"-dev"* ]]; then
  OFFICIAL_BASE="https://ziglang.org/builds"
else
  OFFICIAL_BASE="https://ziglang.org/download/${ZIG_FULL_VER}"
fi

# Check for minisign; prompt to continue without verification if missing
MINISIGN_AVAILABLE=true
if ! command -v minisign &>/dev/null; then
  MINISIGN_AVAILABLE=false
  echo "warning: 'minisign' not found — archive signatures cannot be verified."
  echo "  Install: https://jedisct1.github.io/minisign/"
  read -r -p "  Continue without signature verification? [y/N] " reply
  if [[ ! "$reply" =~ ^[yY]$ ]]; then
    exit 1
  fi
fi

# Fetch community mirrors and shuffle (in background while we do other setup)
echo "Fetching mirrors..."
MIRRORS_FILE=$(mktemp)
trap 'rm -f "$MIRRORS_FILE"' EXIT
{
  MIRROR_RAW=$(curl -fsSL "https://ziglang.org/download/community-mirrors.txt" 2>/dev/null || echo "")
  printf '%s\n' "$MIRROR_RAW" | python3 -c "
import sys, random
lines = [l.strip() for l in sys.stdin if l.strip()]
random.shuffle(lines)
print('\n'.join(lines))
"
  echo "$OFFICIAL_BASE"
} > "$MIRRORS_FILE"

echo "Downloading Zig $ZIG_FULL_VER for all platforms..."

# Track version to detect stale binaries
VERSION_FILE="$SCRIPT_DIR/.zig-version"
if [ -f "$VERSION_FILE" ]; then
  OLD_VER=$(cat "$VERSION_FILE")
  if [ "$OLD_VER" != "$ZIG_FULL_VER" ]; then
    echo "  Version changed ($OLD_VER -> $ZIG_FULL_VER), cleaning old binaries..."
    rm -rf "$SCRIPT_DIR"/darwin-arm64/bin "$SCRIPT_DIR"/darwin-x64/bin \
           "$SCRIPT_DIR"/linux-x64/bin "$SCRIPT_DIR"/linux-arm64/bin \
           "$SCRIPT_DIR"/win32-x64/bin "$SCRIPT_DIR"/win32-arm64/bin
    find "$LIB_DIR" -mindepth 1 -not -name 'package.json' -delete 2>/dev/null || true
  fi
fi

# platform-dir  zig-target           archive-ext
PLATFORMS=(
  "darwin-arm64   aarch64-macos       tar.xz"
  "darwin-x64     x86_64-macos        tar.xz"
  "linux-x64      x86_64-linux        tar.xz"
  "linux-arm64    aarch64-linux       tar.xz"
  "win32-x64      x86_64-windows      zip"
  "win32-arm64    aarch64-windows     zip"
)

# Download, verify, and extract a single platform. Called in a subshell.
download_platform() {
  local dir="$1" target="$2" ext="$3"
  local pkg_dir="$SCRIPT_DIR/$dir"
  local bin_dir="$pkg_dir/bin"
  mkdir -p "$bin_dir"

  if [ -f "$bin_dir/zig" ] || [ -f "$bin_dir/zig.exe" ]; then
    echo "  $dir: already exists, skipping"
    return 0
  fi

  local archive_name="zig-${target}-${ZIG_FULL_VER}.${ext}"
  local extracted_dir="zig-${target}-${ZIG_FULL_VER}"
  local cached_archive="$CACHE_DIR/$ZIG_FULL_VER/$archive_name"
  local cached_minisig="${cached_archive}.minisig"

  _cache_valid() {
    [ -f "$cached_archive" ] || return 1
    if [ "$MINISIGN_AVAILABLE" = true ]; then
      [ -f "$cached_minisig" ] && \
        minisign -V -P "$ZIG_PUBKEY" -m "$cached_archive" -x "$cached_minisig" -q 2>/dev/null
    fi
  }

  if ! _cache_valid; then
    rm -f "$cached_archive" "$cached_minisig"
    mkdir -p "$CACHE_DIR/$ZIG_FULL_VER"
    local fetched=false
    local tmp_archive="${cached_archive}.tmp.$$"
    local tmp_minisig="${cached_minisig}.tmp.$$"

    while IFS= read -r mirror; do
      [ -z "$mirror" ] && continue
      local url="${mirror}/${archive_name}"

      echo "  $dir: trying ${mirror}..."
      curl -fsSL "${url}?source=zigc-npm" -o "$tmp_archive" 2>/dev/null || { rm -f "$tmp_archive"; continue; }

      if [ "$MINISIGN_AVAILABLE" = true ]; then
        curl -fsSL "${url}.minisig?source=zigc-npm" -o "$tmp_minisig" 2>/dev/null || { rm -f "$tmp_archive" "$tmp_minisig"; continue; }

        if ! minisign -V -P "$ZIG_PUBKEY" -m "$tmp_archive" -x "$tmp_minisig" -q 2>/dev/null; then
          echo "  $dir: signature verification failed, skipping mirror"
          rm -f "$tmp_archive" "$tmp_minisig"
          continue
        fi

        local actual_name
        actual_name=$(grep "^trusted comment:" "$tmp_minisig" | sed 's/.*\bfile:\([^ \t]*\).*/\1/')
        if [ "$actual_name" != "$archive_name" ]; then
          echo "  $dir: filename mismatch in signature (got '$actual_name'), skipping mirror"
          rm -f "$tmp_archive" "$tmp_minisig"
          continue
        fi

        mv "$tmp_minisig" "$cached_minisig"
      fi

      mv "$tmp_archive" "$cached_archive"
      fetched=true
      break
    done < "$MIRRORS_FILE"

    if [ "$fetched" = false ]; then
      echo "  $dir: all mirrors failed"
      return 1
    fi
  else
    echo "  $dir: using cached archive"
  fi

  echo "  $dir: extracting..."
  if [ "$ext" = "zip" ]; then
    (cd "$pkg_dir" && unzip -qo "$cached_archive")
    cp "$pkg_dir/$extracted_dir/zig.exe" "$bin_dir/zig.exe"
  else
    (cd "$pkg_dir" && tar xf "$cached_archive")
    cp "$pkg_dir/$extracted_dir/zig" "$bin_dir/zig"
    chmod +x "$bin_dir/zig"
  fi

  # Copy lib/ to shared @zigc/lib package (from linux-x64 only to avoid races)
  if [ "$dir" = "linux-x64" ] && [ ! -d "$LIB_DIR/std" ] && [ -d "$pkg_dir/$extracted_dir/lib" ]; then
    echo "  lib: copying shared lib/ from $dir"
    mkdir -p "$LIB_DIR"
    cp -r "$pkg_dir/$extracted_dir/lib/"* "$LIB_DIR/"
  fi

  rm -rf "$pkg_dir/$extracted_dir"
  echo "  $dir: done"
}

export -f download_platform
export SCRIPT_DIR ZIG_FULL_VER CACHE_DIR LIB_DIR ZIG_PUBKEY MINISIGN_AVAILABLE MIRRORS_FILE

# Download all platforms in parallel
pids=()
for entry in "${PLATFORMS[@]}"; do
  read -r dir target ext <<< "$entry"
  download_platform "$dir" "$target" "$ext" &
  pids+=($!)
done

failed=false
for pid in "${pids[@]}"; do
  wait "$pid" || failed=true
done
if [ "$failed" = true ]; then
  echo "One or more platforms failed to download."
  exit 1
fi

# If lib still not populated (all platforms were cached), extract from linux-x64 now
if [ ! -d "$LIB_DIR/std" ]; then
  read -r _ target ext <<< "${PLATFORMS[2]}"  # linux-x64
  archive_name="zig-${target}-${ZIG_FULL_VER}.${ext}"
  extracted_dir="zig-${target}-${ZIG_FULL_VER}"
  cached_archive="$CACHE_DIR/$ZIG_FULL_VER/$archive_name"
  pkg_dir="$SCRIPT_DIR/linux-x64"
  echo "  lib: extracting from cached linux-x64 archive..."
  (cd "$pkg_dir" && tar xf "$cached_archive" "${extracted_dir}/lib")
  mkdir -p "$LIB_DIR"
  cp -r "$pkg_dir/$extracted_dir/lib/"* "$LIB_DIR/"
  rm -rf "$pkg_dir/$extracted_dir"
fi

# Copy README.md to all packages (in parallel)
echo "Copying README.md to all packages..."
pids=()
for dir in cli lib darwin-arm64 darwin-x64 linux-x64 linux-arm64 win32-x64 win32-arm64; do
  cp "$SCRIPT_DIR/README.md" "$SCRIPT_DIR/$dir/README.md" &
  pids+=($!)
done
for pid in "${pids[@]}"; do wait "$pid"; done

# Save current version
echo "$ZIG_FULL_VER" > "$VERSION_FILE"

echo "All platforms ready!"
