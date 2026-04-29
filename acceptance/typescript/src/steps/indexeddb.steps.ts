import assert from "node:assert/strict";

import { Given, Then, When } from "@cucumber/cucumber";
import {
  createIndexedDbRefHostBridge,
  type GetSuccess,
  type OperationFailure,
  type SideshowdbCoreClient,
  type SideshowdbDocumentEnvelope,
} from "@sideshowdb/core";
import { createIndexedDbRefHostBridgeEffect } from "@sideshowdb/effect";
import { Cause, Effect, Exit, Option } from "effect";
import { indexedDB as fakeIndexedDb } from "fake-indexeddb";

import { loadAcceptanceIndexedDbClient } from "../support/wasm.js";
import { AcceptanceWorld } from "../support/world.js";

type Bridge = Awaited<ReturnType<typeof createIndexedDbRefHostBridge>>;

type IndexedDbState = {
  previousIndexedDb?: unknown;
  bridge?: Bridge;
  secondBridge?: Bridge;
  defaultClient?: SideshowdbCoreClient;
  defaultClientDbName?: string;
  bridgeCreateError?: unknown;
  persistenceErrorCalls?: Error[];
  blockedDb?: IDBDatabase;
};

Given("IndexedDB is available for acceptance tests", function (this: AcceptanceWorld) {
  this.indexedDbState = this.indexedDbState ?? {};
  this.indexedDbState.previousIndexedDb = globalThis.indexedDB;
  globalThis.indexedDB = fakeIndexedDb;
});

Given("IndexedDB is unavailable for acceptance tests", function (this: AcceptanceWorld) {
  this.indexedDbState = this.indexedDbState ?? {};
  this.indexedDbState.previousIndexedDb = globalThis.indexedDB;
  delete (globalThis as { indexedDB?: unknown }).indexedDB;
});

Given(
  "an IndexedDB host bridge database {string} exists with store {string}",
  async function (this: AcceptanceWorld, dbName: string, storeName: string) {
    const bridge = await createIndexedDbRefHostBridge({ dbName, storeName });
    bridge.put("seed-key", "seed-value");
    await flushWrites();
  },
);

Given(
  "an external IndexedDB connection blocks upgrades for database {string}",
  async function (this: AcceptanceWorld, dbName: string) {
    const state = getIndexedDbState(this);
    state.blockedDb = await openRawDb(dbName);
  },
);

Given(
  "an IndexedDB host bridge on database {string} with store {string}",
  async function (this: AcceptanceWorld, dbName: string, storeName: string) {
    const state = getIndexedDbState(this);
    state.bridge = await createIndexedDbRefHostBridge({ dbName, storeName });
  },
);

When("I create an IndexedDB host bridge through the Effect binding", async function (this: AcceptanceWorld) {
  const state = getIndexedDbState(this);
  const exit = await Effect.runPromiseExit(createIndexedDbRefHostBridgeEffect());
  if (Exit.isSuccess(exit)) {
    state.bridge = exit.value;
    state.bridgeCreateError = undefined;
    return;
  }

  const failure = Cause.failureOption(exit.cause);
  if (Option.isSome(failure)) {
    state.bridgeCreateError = failure.value;
    state.bridge = undefined;
    return;
  }

  state.bridgeCreateError = new Error("Unknown IndexedDB bridge creation failure");
  state.bridge = undefined;
});

When(
  "I open an IndexedDB host bridge on database {string} with store {string}",
  async function (this: AcceptanceWorld, dbName: string, storeName: string) {
    const state = getIndexedDbState(this);
    try {
      state.bridge = await createIndexedDbRefHostBridge({ dbName, storeName });
      state.bridgeCreateError = undefined;
    } catch (error) {
      state.bridgeCreateError = error;
      state.bridge = undefined;
    }
  },
);

When(
  "I open an IndexedDB host bridge on database {string} with store {string} and persistence error hook",
  async function (this: AcceptanceWorld, dbName: string, storeName: string) {
    const state = getIndexedDbState(this);
    state.persistenceErrorCalls = [];
    try {
      state.bridge = await createIndexedDbRefHostBridge({
        dbName,
        storeName,
        onPersistenceError: (error: Error) => state.persistenceErrorCalls?.push(error),
      });
      state.bridgeCreateError = undefined;
    } catch (error) {
      state.bridgeCreateError = error;
      state.bridge = undefined;
    }
  },
);

When(
  "I put key {string} with value {string} through the IndexedDB host bridge",
  function (this: AcceptanceWorld, key: string, value: string) {
    const bridge = requireBridge(this);
    bridge.put(key, value);
  },
);

When(
  "I open a second IndexedDB host bridge on database {string} with store {string}",
  async function (this: AcceptanceWorld, dbName: string, storeName: string) {
    const state = getIndexedDbState(this);
    state.secondBridge = await createIndexedDbRefHostBridge({ dbName, storeName });
  },
);

When("I close the IndexedDB host bridge", async function (this: AcceptanceWorld) {
  await requireBridge(this).close();
});

When(
  "I reopen the IndexedDB host bridge on database {string} with store {string}",
  async function (this: AcceptanceWorld, dbName: string, storeName: string) {
    const state = getIndexedDbState(this);
    state.bridge = await createIndexedDbRefHostBridge({ dbName, storeName });
  },
);

When(
  "I load the default IndexedDB-backed client for database {string}",
  async function (this: AcceptanceWorld, dbName: string) {
    const state = getIndexedDbState(this);
    state.defaultClientDbName = dbName;
    state.defaultClient = await loadAcceptanceIndexedDbClient(dbName);
  },
);

When(
  "I put document {string} of type {string} with JSON body through the default IndexedDB client:",
  async function (this: AcceptanceWorld, id: string, type: string, docString: string) {
    const client = requireDefaultClient(this);
    const result = await client.put({
      type,
      id,
      data: JSON.parse(docString) as Record<string, unknown>,
    });
    assert.equal(result.ok, true, `expected default client put success, got ${JSON.stringify(result)}`);
  },
);

When(
  "I reload the default IndexedDB-backed client for database {string}",
  async function (this: AcceptanceWorld, dbName: string) {
    const state = getIndexedDbState(this);
    state.defaultClientDbName = dbName;
    state.defaultClient = await loadAcceptanceIndexedDbClient(dbName);
  },
);

Then("the IndexedDB host bridge is created", function (this: AcceptanceWorld) {
  const state = getIndexedDbState(this);
  assert.notEqual(state.bridge, undefined);
  assert.equal(state.bridgeCreateError, undefined);
});

Then(
  "IndexedDB host bridge creation fails with error kind {string}",
  function (this: AcceptanceWorld, kind: string) {
    const error = getIndexedDbState(this).bridgeCreateError as
      | {
          kind?: string;
          error?: { kind?: string };
          cause?: { failure?: { kind?: string } };
        }
      | undefined;
    assert.notEqual(error, undefined);
    const resolvedKind = error?.kind ?? error?.error?.kind ?? error?.cause?.failure?.kind;
    assert.equal(
      resolvedKind,
      kind,
      `expected error kind '${kind}', got ${JSON.stringify(error)}`,
    );
  },
);

Then("IndexedDB host bridge creation fails", function (this: AcceptanceWorld) {
  assert.notEqual(getIndexedDbState(this).bridgeCreateError, undefined);
});

Then(
  "getting key {string} through the IndexedDB host bridge returns value {string}",
  function (this: AcceptanceWorld, key: string, value: string) {
    const result = requireBridge(this).get(key);
    assert.deepEqual(result, { value, version: "v1" });
  },
);

Then(
  "getting key {string} through the second IndexedDB host bridge returns value {string}",
  function (this: AcceptanceWorld, key: string, value: string) {
    const bridge = getIndexedDbState(this).secondBridge;
    if (bridge === undefined) {
      throw new Error("expected second IndexedDB bridge to exist");
    }
    const result = bridge.get(key);
    assert.deepEqual(result, { value, version: "v1" });
  },
);

Then(
  "getting key {string} through the reopened IndexedDB host bridge returns value {string}",
  function (this: AcceptanceWorld, key: string, value: string) {
    const result = requireBridge(this).get(key);
    assert.deepEqual(result, { value, version: "v1" });
  },
);

Then(
  "getting document {string} of type {string} through the default IndexedDB client returns JSON body:",
  async function (this: AcceptanceWorld, id: string, type: string, docString: string) {
    const expected = JSON.parse(docString) as Record<string, unknown>;
    const dbName = getIndexedDbState(this).defaultClientDbName;
    assert.notEqual(dbName, undefined, "expected default IndexedDB client database name");

    const result = await readPersistedDocument(dbName as string, type, id);
    assert.equal(result.ok, true, `expected default client get success, got ${JSON.stringify(result)}`);
    if (!result.ok) {
      throw new Error("expected default client get success");
    }
    assert.equal(result.found, true, "expected persisted document to be found");
    if (!result.found) {
      throw new Error("expected persisted document to exist");
    }
    assert.deepEqual(result.value.data, expected);
  },
);

Then("the IndexedDB persistence error hook was called", function (this: AcceptanceWorld) {
  const calls = getIndexedDbState(this).persistenceErrorCalls ?? [];
  assert.ok(calls.length > 0, "expected persistence error hook to be called");
});

Then("IndexedDB availability is restored for acceptance tests", function (this: AcceptanceWorld) {
  const state = getIndexedDbState(this);
  (globalThis as { indexedDB?: unknown }).indexedDB = state.previousIndexedDb;
});

Then("I release the external IndexedDB blocker", function (this: AcceptanceWorld) {
  const state = getIndexedDbState(this);
  state.blockedDb?.close();
});

function getIndexedDbState(world: AcceptanceWorld): IndexedDbState {
  world.indexedDbState = world.indexedDbState ?? {};
  return world.indexedDbState as IndexedDbState;
}

function requireBridge(world: AcceptanceWorld): Bridge {
  const bridge = getIndexedDbState(world).bridge;
  if (bridge === undefined) {
    throw new Error("expected IndexedDB bridge to exist");
  }
  return bridge;
}

function requireDefaultClient(world: AcceptanceWorld): SideshowdbCoreClient {
  const client = getIndexedDbState(world).defaultClient;
  if (client === undefined) {
    throw new Error("expected default IndexedDB client to exist");
  }
  return client;
}

async function openRawDb(dbName: string): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(dbName);
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error ?? new Error("Unable to open raw IndexedDB."));
  });
}

async function flushWrites(ticks = 5): Promise<void> {
  for (let i = 0; i < ticks; i += 1) {
    await Promise.resolve();
  }
}

async function readPersistedDocument(
  dbName: string,
  type: string,
  id: string,
): Promise<OperationFailure | GetSuccess<SideshowdbDocumentEnvelope<Record<string, unknown>>>> {
  for (let attempt = 0; attempt < 10; attempt += 1) {
    const client = await loadAcceptanceIndexedDbClient(dbName);
    const result = await client.get<Record<string, unknown>>({
      type,
      id,
    });
    if (!result.ok) {
      return result;
    }
    if (result.found) {
      return result;
    }
    await Promise.resolve();
  }

  return {
    ok: true,
    found: false,
  };
}
