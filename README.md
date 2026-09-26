# @zigc/cli

Zig compiler via npm. Useful when Zig is not installed system-wide or only npm is available (e.g. CI).

## Usage

```bash
npx @zigc/cli version
bunx @zigc/cli version

# Or install globally
npm install -g @zigc/cli
zig version
```

## How it works

`@zigc/cli` picks the native binary for your platform through optional dependencies:

| Package | Platform |
|---------|----------|
| `@zigc/darwin-arm64` | macOS Apple Silicon |
| `@zigc/darwin-x64` | macOS Intel |
| `@zigc/linux-x64` | Linux x64 |
| `@zigc/linux-arm64` | Linux ARM64 |
| `@zigc/win32-x64` | Windows x64 |
| `@zigc/win32-arm64` | Windows ARM64 |

The standard library lives in `@zigc/lib` (shared across platforms).

## WASI / WebAssembly

`@zigc/wasm32-wasi` provides the Zig compiler as `zig.wasm` for WASI runtimes and for embedding in workers.

```bash
npx @zigc/wasm32-wasi version
# after install:
zig-wasi version
```

Load the wasm yourself:

```js
import { wasmURL, wasmPath } from '@zigc/wasm32-wasi';

const bytes = await fetch(wasmURL).then((r) => r.arrayBuffer());
const module = await WebAssembly.compile(bytes);
// Instantiate with your WASI implementation; preopen @zigc/lib and set ZIG_LIB_DIR.
```

Preopen `@zigc/lib` into the WASI instance and set `ZIG_LIB_DIR`.
