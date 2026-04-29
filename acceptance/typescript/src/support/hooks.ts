import { After } from "@cucumber/cucumber";
import { rm } from "node:fs/promises";

import { AcceptanceWorld } from "./world.js";

After(async function (this: AcceptanceWorld) {
  if (this.repoDir !== null) {
    await rm(this.repoDir, { recursive: true, force: true });
  }

  const state = this.indexedDbState as
    | {
        bridge?: { close?: () => Promise<void> | void };
        secondBridge?: { close?: () => Promise<void> | void };
        previousIndexedDb?: unknown;
        blockedDb?: IDBDatabase;
      }
    | null;
  if (state?.bridge?.close) {
    await state.bridge.close();
  }
  if (state?.secondBridge?.close) {
    await state.secondBridge.close();
  }
  if (state?.blockedDb) {
    state.blockedDb.close();
  }
  if (state && "previousIndexedDb" in state) {
    (globalThis as { indexedDB?: unknown }).indexedDB = state.previousIndexedDb;
  }
});
