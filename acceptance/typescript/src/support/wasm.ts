import { readFile } from "node:fs/promises";

import {
  loadSideshowdbClient,
  type SideshowdbCoreClient,
  type SideshowdbRefHostBridge,
} from "@sideshowdb/core";

const wasmFixturePath = new URL(
  "../../../../zig-out/wasm/sideshowdb.wasm",
  import.meta.url,
);

export async function loadAcceptanceWasmClient(
  hostBridge?: SideshowdbRefHostBridge,
): Promise<SideshowdbCoreClient> {
  const bytes = await readFile(wasmFixturePath);

  return loadSideshowdbClient({
    wasmPath: "/fixtures/sideshowdb.wasm",
    hostBridge,
    fetchImpl: async () => ({
      ok: true,
      arrayBuffer: async () =>
        bytes.buffer.slice(
          bytes.byteOffset,
          bytes.byteOffset + bytes.byteLength,
        ) as ArrayBuffer,
    }),
  });
}
