# @zigc/cli

Zig compiler distributed via npm. Run Zig without installing it system-wide or in CI/CD where Zig is not available and/or only NPM is available.

## Usage

```bash
# Run directly
npx @zigc/cli version
bunx @zigc/cli version

# Or install globally
npm install -g @zigc/cli
zig version
```

## How it works

The `@zigc/cli` package resolves the correct native binary for your platform via optional dependencies:

| Package | Platform |
|---------|----------|
| `@zigc/darwin-arm64` | macOS Apple Silicon |
| `@zigc/darwin-x64` | macOS Intel |
| `@zigc/linux-x64` | Linux x64 |
| `@zigc/linux-arm64` | Linux ARM64 |
| `@zigc/win32-x64` | Windows x64 |
| `@zigc/win32-arm64` | Windows ARM64 |

The standard library is shipped separately in `@zigc/lib` (shared across all platforms).