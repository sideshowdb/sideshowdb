import assert from "node:assert/strict";

import { Given, Then, When, type DataTable } from "@cucumber/cucumber";
import type {
  OperationFailure,
  OperationSuccess,
  SideshowDbCoreClient,
  SideshowDbDeleteResult,
  SideshowDbDocumentEnvelope,
  SideshowDbHistoryResult,
  SideshowDbListResult,
  SideshowDbHostStore,
} from "@sideshowdb/core";

import { createMemoryRefHostStore } from "../support/memory-ref-host-store.js";
import { loadAcceptanceWasmClient } from "../support/wasm.js";
import { AcceptanceWorld } from "../support/world.js";

type WasmState = {
  hostStore?: SideshowDbHostStore;
};

type IssueDocument = {
  title: string;
};

const documentRef = {
  type: "summary",
  id: "doc-1",
} as const;

Given("an in-memory WASM host store", function (this: AcceptanceWorld) {
  this.wasmResult = {
    hostStore: createMemoryRefHostStore(),
  };
});

Given("no WASM host store", function (this: AcceptanceWorld) {
  this.wasmResult = {};
});

Given("the WASM client is loaded", async function (this: AcceptanceWorld) {
  const state = getState(this);
  this.wasmClient = (await loadAcceptanceWasmClient(state.hostStore)) as never;
  this.wasmResult = null;
});

When(
  "I put the first document version through the WASM binding",
  async function (this: AcceptanceWorld) {
    const client = getClient(this);
    this.wasmResult = (await client.put<IssueDocument>({
      type: documentRef.type,
      id: documentRef.id,
      data: { title: "first" },
    })) as never;
  },
);

When(
  "I put the second document version through the WASM binding",
  async function (this: AcceptanceWorld) {
    const client = getClient(this);
    this.wasmResult = (await client.put<IssueDocument>({
      type: documentRef.type,
      id: documentRef.id,
      data: { title: "second" },
    })) as never;
  },
);

When(
  "I put document {string} of type {string} in namespace {string} through the WASM binding with JSON body:",
  async function (this: AcceptanceWorld, id: string, type: string, namespace: string, docString: string) {
    const client = getClient(this);
    this.wasmResult = (await client.put<Record<string, unknown>>({
      namespace,
      type,
      id,
      data: JSON.parse(normalizeJsonDocString(docString)) as Record<string, unknown>,
    })) as never;
  },
);

When("I get the document through the WASM binding", async function (this: AcceptanceWorld) {
  const client = getClient(this);
  this.wasmResult = (await client.get<IssueDocument>({
    type: documentRef.type,
    id: documentRef.id,
  })) as never;
});

When(
  "I get document {string} of type {string} in namespace {string} through the WASM binding",
  async function (this: AcceptanceWorld, id: string, type: string, namespace: string) {
    const client = getClient(this);
    this.wasmResult = (await client.get<Record<string, unknown>>({
      namespace,
      type,
      id,
    })) as never;
  },
);

When("I list documents through the WASM binding", async function (this: AcceptanceWorld) {
  const client = getClient(this);
  this.wasmResult = (await client.list({
    type: documentRef.type,
  })) as never;
});

When(
  "I list documents of type {string} in namespace {string} through the WASM binding in summary mode",
  async function (this: AcceptanceWorld, type: string, namespace: string) {
    const client = getClient(this);
    this.wasmResult = (await client.list({
      namespace,
      type,
      mode: "summary",
    })) as never;
  },
);

When(
  "I request detailed history through the WASM binding",
  async function (this: AcceptanceWorld) {
    const client = getClient(this);
    this.wasmResult = (await client.history<IssueDocument>({
      type: documentRef.type,
      id: documentRef.id,
      mode: "detailed",
    })) as never;
  },
);

When(
  "I request document history for {string} of type {string} in namespace {string} through the WASM binding in detailed mode",
  async function (this: AcceptanceWorld, id: string, type: string, namespace: string) {
    const client = getClient(this);
    this.wasmResult = (await client.history<Record<string, unknown>>({
      namespace,
      type,
      id,
      mode: "detailed",
    })) as never;
  },
);

When("I delete the document through the WASM binding", async function (this: AcceptanceWorld) {
  const client = getClient(this);
  this.wasmResult = (await client.delete({
    type: documentRef.type,
    id: documentRef.id,
  })) as never;
});

When(
  "I put a document through the WASM binding without a host store",
  async function (this: AcceptanceWorld) {
    const client = getClient(this);
    this.wasmResult = (await client.put<IssueDocument>({
      type: documentRef.type,
      id: documentRef.id,
      data: { title: "first" },
    })) as never;
  },
);

When(
  "I get document {string} of type {string} in namespace {string} at remembered version {string} through the WASM binding",
  async function (this: AcceptanceWorld, id: string, type: string, namespace: string, rememberedVersion: string) {
    const client = getClient(this);
    this.wasmResult = (await client.get<Record<string, unknown>>({
      namespace,
      type,
      id,
      version: requireRememberedValue(this, rememberedVersion),
    })) as never;
  },
);

Then("the WASM get result title is {string}", function (this: AcceptanceWorld, title: string) {
  const result = getStoredResult(this);
  assert.equal(result.ok, true);
  assert.equal("found" in result, true);
  if (!result.ok || !("found" in result)) {
    throw new Error("expected a stored WASM get result");
  }

  assert.equal(result.found, true);
  if (!result.found) {
    throw new Error("expected document to be present");
  }

  assert.equal(result.value.data.title, title);
});

Then("the WASM list result kind is {string}", function (this: AcceptanceWorld, kind: string) {
  const result = getStoredResult(this) as OperationSuccess<SideshowDbListResult>;
  assert.equal(result.ok, true);
  if (!result.ok) {
    throw new Error("expected a stored WASM list result");
  }

  assert.equal(result.value.kind, kind);
});

Then(
  "the WASM history result contains {int} entries",
  function (this: AcceptanceWorld, count: number) {
    const result = getStoredResult(this) as OperationSuccess<SideshowDbHistoryResult<IssueDocument>>;
    assert.equal(result.ok, true);
    if (!result.ok) {
      throw new Error("expected a stored WASM history result");
    }

    assert.equal(result.value.kind, "detailed");
    if (result.value.kind !== "detailed") {
      throw new Error("expected detailed history");
    }

    assert.equal(result.value.items.length, count);
  },
);

Then("the WASM delete result is true", function (this: AcceptanceWorld) {
  const result = getStoredResult(this) as OperationSuccess<SideshowDbDeleteResult>;
  assert.equal(result.ok, true);
  if (!result.ok) {
    throw new Error("expected a stored WASM delete result");
  }

  assert.equal(result.value.deleted, true);
});

Then("the WASM operation succeeds", function (this: AcceptanceWorld) {
  const result = getStoredResult(this);
  assert.equal(result.ok, true, `expected WASM operation success, got ${JSON.stringify(result)}`);
});

Then("I remember the WASM envelope version as {string}", function (this: AcceptanceWorld, key: string) {
  const result = getStoredResult(this);
  assert.equal(result.ok, true, `expected WASM success before remembering version, got ${JSON.stringify(result)}`);
  if (!result.ok || !("value" in result) || !isEnvelopeResult(result.value)) {
    throw new Error("expected a successful WASM envelope result");
  }
  this.rememberedValues[key] = requireString(result.value.version, "version");
});

Then("the WASM summary items are:", function (this: AcceptanceWorld, dataTable: DataTable) {
  const result = getStoredResult(this) as OperationSuccess<SideshowDbListResult>;
  assert.equal(result.ok, true);
  if (!result.ok) {
    throw new Error("expected a stored WASM list result");
  }

  const items = result.value.items.map((item) => ({
    namespace: item.namespace,
    type: item.type,
    id: item.id,
  }));
  assert.deepEqual(items, dataTable.hashes());
});

Then("the WASM history items match:", function (this: AcceptanceWorld, dataTable: DataTable) {
  const result = getStoredResult(this) as OperationSuccess<SideshowDbHistoryResult<Record<string, unknown>>>;
  assert.equal(result.ok, true);
  if (!result.ok) {
    throw new Error("expected a stored WASM history result");
  }

  assert.equal(result.value.kind, "detailed");
  if (result.value.kind !== "detailed") {
    throw new Error("expected detailed history");
  }

  const items = result.value.items.map((item) => ({
    remembered_version: requireResolvedVersionAlias(this, item.version),
    title: requireTitle(item.data),
    namespace: item.namespace,
    type: item.type,
    id: item.id,
  }));
  assert.deepEqual(items, dataTable.hashes());
});

Then("the WASM document body equals:", function (this: AcceptanceWorld, docString: string) {
  const result = getStoredResult(this);
  assert.equal(result.ok, true);
  assert.equal("found" in result, true);
  if (!result.ok || !("found" in result) || !result.found) {
    throw new Error("expected a found WASM document result");
  }

  assert.deepEqual(result.value.data, JSON.parse(normalizeJsonDocString(docString)));
});

Then(
  "the WASM operation fails with error kind {string}",
  function (this: AcceptanceWorld, kind: string) {
    const result = getStoredResult(this) as OperationFailure;
    assert.equal(result.ok, false);
    if (result.ok) {
      throw new Error("expected a stored WASM failure result");
    }

    assert.equal(result.error.kind, kind);
  },
);

function getState(world: AcceptanceWorld): WasmState {
  return (world.wasmResult ?? {}) as WasmState;
}

function getClient(world: AcceptanceWorld): SideshowDbCoreClient {
  assert.notEqual(world.wasmClient, null, "expected WASM client to be loaded");
  return world.wasmClient as unknown as SideshowDbCoreClient;
}

function getStoredResult(
  world: AcceptanceWorld,
):
  | OperationFailure
  | OperationSuccess<SideshowDbDeleteResult>
  | OperationSuccess<SideshowDbListResult>
  | OperationSuccess<SideshowDbHistoryResult<IssueDocument>>
  | { ok: true; found: false }
  | { ok: true; found: true; value: SideshowDbDocumentEnvelope<IssueDocument> } {
  assert.notEqual(world.wasmResult, null, "expected a stored WASM result");
  return world.wasmResult as ReturnType<typeof getStoredResult>;
}

function requireRememberedValue(world: AcceptanceWorld, key: string): string {
  const value = world.rememberedValues[key];
  if (typeof value !== "string") {
    throw new Error(`expected remembered value ${key} to exist`);
  }
  return value;
}

function requireResolvedVersionAlias(world: AcceptanceWorld, version: string): string {
  for (const [alias, remembered] of Object.entries(world.rememberedValues)) {
    if (remembered === version) {
      return alias;
    }
  }
  return version;
}

function requireString(value: unknown, label: string): string {
  if (typeof value !== "string") {
    throw new Error(`expected ${label} to be a string`);
  }
  return value;
}

function requireTitle(data: unknown): string {
  if (typeof data !== "object" || data === null || !("title" in data)) {
    throw new Error("expected data.title to exist");
  }
  return requireString((data as { title: unknown }).title, "data.title");
}

function normalizeJsonDocString(docString: string): string {
  return `${docString.trim()}\n`;
}

function isEnvelopeResult(value: unknown): value is SideshowDbDocumentEnvelope<Record<string, unknown>> {
  return typeof value === "object" && value !== null && "version" in value && "data" in value;
}
