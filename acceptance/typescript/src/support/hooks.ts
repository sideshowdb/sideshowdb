import { After, Before } from "@cucumber/cucumber";
import { mkdtemp, rm } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { GitHubMock } from "./github-mock.js";

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

Before({ tags: "@github" }, async function (this: AcceptanceWorld) {
  this.githubMock = new GitHubMock();
  await this.githubMock.serve();
  this.repoDir = await mkdtemp(join(tmpdir(), "sideshowdb-gh-"));
});

After({ tags: "@github" }, async function (this: AcceptanceWorld) {
  if (this.githubMock) {
    await this.githubMock.stop();
    this.githubMock = null;
  }
});
