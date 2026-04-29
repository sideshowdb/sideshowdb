import assert from "node:assert/strict";

import { Given, Then, When } from "@cucumber/cucumber";
import {
  createIndexedDbHostStore,
  type GetSuccess,
  type OperationFailure,
  type SideshowDbCoreClient,
  type SideshowDbDocumentEnvelope,
} from "@sideshowdb/core";
import { createIndexedDbHostStoreEffect } from "@sideshowdb/effect";
import { Cause, Effect, Exit, Option } from "effect";
import { indexedDB as fakeIndexedDb } from "fake-indexeddb";

import { loadAcceptanceIndexedDbClient } from "../support/wasm.js";
import { AcceptanceWorld } from "../support/world.js";

type HostStore = Awaited<ReturnType<typeof createIndexedDbHostStore>>;

type IndexedDbState = {
  previousIndexedDb?: unknown;
  hostStore?: HostStore;
  secondHostStore?: HostStore;
  defaultClient?: SideshowDbCoreClient;
  defaultClientDbName?: string;
  hostStoreCreateError?: unknown;
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
  "an IndexedDB host store database {string} exists with store {string}",
  async function (this: AcceptanceWorld, dbName: string, storeName: string) {
    const hostStore = await createIndexedDbHostStore({ dbName, storeName });
    hostStore.put("seed-key", "seed-value");
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
  "an IndexedDB host store on database {string} with store {string}",
  async function (this: AcceptanceWorld, dbName: string, storeName: string) {
    const state = getIndexedDbState(this);
    state.hostStore = await createIndexedDbHostStore({ dbName, storeName });
  },
);

When("I create an IndexedDB host store through the Effect binding", async function (this: AcceptanceWorld) {
  const state = getIndexedDbState(this);
  const exit = await Effect.runPromiseExit(createIndexedDbHostStoreEffect());
  if (Exit.isSuccess(exit)) {
    state.hostStore = exit.value;
    state.hostStoreCreateError = undefined;
    return;
  }

  const failure = Cause.failureOption(exit.cause);
  if (Option.isSome(failure)) {
    state.hostStoreCreateError = failure.value;
    state.hostStore = undefined;
    return;
  }

  state.hostStoreCreateError = new Error("Unknown IndexedDB host store creation failure");
  state.hostStore = undefined;
});

When(
  "I open an IndexedDB host store on database {string} with store {string}",
  async function (this: AcceptanceWorld, dbName: string, storeName: string) {
    const state = getIndexedDbState(this);
    try {
      state.hostStore = await createIndexedDbHostStore({ dbName, storeName });
      state.hostStoreCreateError = undefined;
    } catch (error) {
      state.hostStoreCreateError = error;
      state.hostStore = undefined;
    }
  },
);

When(
  "I open an IndexedDB host store on database {string} with store {string} and persistence error hook",
  async function (this: AcceptanceWorld, dbName: string, storeName: string) {
    const state = getIndexedDbState(this);
    state.persistenceErrorCalls = [];
    try {
      state.hostStore = await createIndexedDbHostStore({
        dbName,
        storeName,
        onPersistenceError: (error: Error) => state.persistenceErrorCalls?.push(error),
      });
      state.hostStoreCreateError = undefined;
    } catch (error) {
      state.hostStoreCreateError = error;
      state.hostStore = undefined;
    }
  },
);

When(
  "I put key {string} with value {string} through the IndexedDB host store",
  function (this: AcceptanceWorld, key: string, value: string) {
    const hostStore = requireHostStore(this);
    hostStore.put(key, value);
  },
);

When(
  "I open a second IndexedDB host store on database {string} with store {string}",
  async function (this: AcceptanceWorld, dbName: string, storeName: string) {
    const state = getIndexedDbState(this);
    state.secondHostStore = await createIndexedDbHostStore({ dbName, storeName });
  },
);

When("I close the IndexedDB host store", async function (this: AcceptanceWorld) {
  await requireHostStore(this).close();
});

When(
  "I reopen the IndexedDB host store on database {string} with store {string}",
  async function (this: AcceptanceWorld, dbName: string, storeName: string) {
    const state = getIndexedDbState(this);
    state.hostStore = await createIndexedDbHostStore({ dbName, storeName });
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

Then("the IndexedDB host store is created", function (this: AcceptanceWorld) {
  const state = getIndexedDbState(this);
  assert.notEqual(state.hostStore, undefined);
  assert.equal(state.hostStoreCreateError, undefined);
});

Then(
  "IndexedDB host store creation fails with error kind {string}",
  function (this: AcceptanceWorld, kind: string) {
    const error = getIndexedDbState(this).hostStoreCreateError as
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

Then("IndexedDB host store creation fails", function (this: AcceptanceWorld) {
  assert.notEqual(getIndexedDbState(this).hostStoreCreateError, undefined);
});

Then(
  "getting key {string} through the IndexedDB host store returns value {string}",
  function (this: AcceptanceWorld, key: string, value: string) {
    const result = requireHostStore(this).get(key);
    assert.deepEqual(result, { value, version: "v1" });
  },
);

Then(
  "getting key {string} through the second IndexedDB host store returns value {string}",
  function (this: AcceptanceWorld, key: string, value: string) {
    const hostStore = getIndexedDbState(this).secondHostStore;
    if (hostStore === undefined) {
      throw new Error("expected second IndexedDB host store to exist");
    }
    const result = hostStore.get(key);
    assert.deepEqual(result, { value, version: "v1" });
  },
);

Then(
  "getting key {string} through the reopened IndexedDB host store returns value {string}",
  function (this: AcceptanceWorld, key: string, value: string) {
    const result = requireHostStore(this).get(key);
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

function requireHostStore(world: AcceptanceWorld): HostStore {
  const hostStore = getIndexedDbState(world).hostStore;
  if (hostStore === undefined) {
    throw new Error("expected IndexedDB host store to exist");
  }
  return hostStore;
}

function requireDefaultClient(world: AcceptanceWorld): SideshowDbCoreClient {
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
): Promise<OperationFailure | GetSuccess<SideshowDbDocumentEnvelope<Record<string, unknown>>>> {
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
