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
  return loadAcceptanceClient({
    hostBridge,
  });
}

export async function loadAcceptanceIndexedDbClient(
  dbName: string,
): Promise<SideshowdbCoreClient> {
  return loadAcceptanceClient({
    indexedDb: { dbName },
  });
}

async function loadAcceptanceClient(options: {
  hostBridge?: SideshowdbRefHostBridge;
  indexedDb?: false | { dbName?: string; storeName?: string };
}): Promise<SideshowdbCoreClient> {
  const bytes = await readFile(wasmFixturePath);

  return loadSideshowdbClient({
    wasmPath: "/fixtures/sideshowdb.wasm",
    hostBridge: options.hostBridge,
    indexedDb: options.indexedDb,
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
