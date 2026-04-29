import { readFile } from "node:fs/promises";

import {
  loadSideshowDbClient,
  type SideshowDbCoreClient,
  type SideshowDbHostStore,
} from "@sideshowdb/core";

const wasmFixturePath = new URL(
  "../../../../zig-out/wasm/sideshowdb.wasm",
  import.meta.url,
);

export async function loadAcceptanceWasmClient(
  hostStore?: SideshowDbHostStore,
): Promise<SideshowDbCoreClient> {
  return loadAcceptanceClient({
    hostStore,
  });
}

export async function loadAcceptanceIndexedDbClient(
  dbName: string,
): Promise<SideshowDbCoreClient> {
  return loadAcceptanceClient({
    indexedDb: { dbName },
  });
}

async function loadAcceptanceClient(options: {
  hostStore?: SideshowDbHostStore;
  indexedDb?: false | { dbName?: string; storeName?: string };
}): Promise<SideshowDbCoreClient> {
  const bytes = await readFile(wasmFixturePath);

  return loadSideshowDbClient({
    wasmPath: "/fixtures/sideshowdb.wasm",
    hostCapabilities: { store: options.hostStore },
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
