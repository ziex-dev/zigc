import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));

/** Absolute filesystem path to zig.wasm (Node / bundlers that resolve paths). */
export const wasmPath = join(__dirname, 'bin', 'zig.wasm');

/** URL to zig.wasm — use with `fetch(wasmURL)` in workers / browsers. */
export const wasmURL = new URL('./bin/zig.wasm', import.meta.url);

export default wasmPath;
