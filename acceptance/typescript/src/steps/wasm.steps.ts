import assert from "node:assert/strict";

import { Given, Then, When } from "@cucumber/cucumber";
import type {
  OperationFailure,
  OperationSuccess,
  SideshowdbCoreClient,
  SideshowdbDeleteResult,
  SideshowdbDocumentEnvelope,
  SideshowdbHistoryResult,
  SideshowdbListResult,
  SideshowdbRefHostBridge,
} from "@sideshowdb/core";

import { createMemoryRefHostBridge } from "../support/memory-ref-host-bridge.js";
import { loadAcceptanceWasmClient } from "../support/wasm.js";
import { AcceptanceWorld } from "../support/world.js";

type WasmState = {
  hostBridge?: SideshowdbRefHostBridge;
};

type IssueDocument = {
  title: string;
};

const documentRef = {
  type: "summary",
  id: "doc-1",
} as const;

Given("an in-memory WASM host bridge", function (this: AcceptanceWorld) {
  this.wasmResult = {
    hostBridge: createMemoryRefHostBridge(),
  };
});

Given("no WASM host bridge", function (this: AcceptanceWorld) {
  this.wasmResult = {};
});

Given("the WASM client is loaded", async function (this: AcceptanceWorld) {
  const state = getState(this);
  this.wasmClient = (await loadAcceptanceWasmClient(state.hostBridge)) as never;
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

When("I get the document through the WASM binding", async function (this: AcceptanceWorld) {
  const client = getClient(this);
  this.wasmResult = (await client.get<IssueDocument>({
    type: documentRef.type,
    id: documentRef.id,
  })) as never;
});

When("I list documents through the WASM binding", async function (this: AcceptanceWorld) {
  const client = getClient(this);
  this.wasmResult = (await client.list({
    type: documentRef.type,
  })) as never;
});

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

When("I delete the document through the WASM binding", async function (this: AcceptanceWorld) {
  const client = getClient(this);
  this.wasmResult = (await client.delete({
    type: documentRef.type,
    id: documentRef.id,
  })) as never;
});

When(
  "I put a document through the WASM binding without a host bridge",
  async function (this: AcceptanceWorld) {
    const client = getClient(this);
    this.wasmResult = (await client.put<IssueDocument>({
      type: documentRef.type,
      id: documentRef.id,
      data: { title: "first" },
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
  const result = getStoredResult(this) as OperationSuccess<SideshowdbListResult>;
  assert.equal(result.ok, true);
  if (!result.ok) {
    throw new Error("expected a stored WASM list result");
  }

  assert.equal(result.value.kind, kind);
});

Then(
  "the WASM history result contains {int} entries",
  function (this: AcceptanceWorld, count: number) {
    const result = getStoredResult(this) as OperationSuccess<SideshowdbHistoryResult<IssueDocument>>;
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
  const result = getStoredResult(this) as OperationSuccess<SideshowdbDeleteResult>;
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

function getClient(world: AcceptanceWorld): SideshowdbCoreClient {
  assert.notEqual(world.wasmClient, null, "expected WASM client to be loaded");
  return world.wasmClient as unknown as SideshowdbCoreClient;
}

function getStoredResult(
  world: AcceptanceWorld,
):
  | OperationFailure
  | OperationSuccess<SideshowdbDeleteResult>
  | OperationSuccess<SideshowdbListResult>
  | OperationSuccess<SideshowdbHistoryResult<IssueDocument>>
  | { ok: true; found: false }
  | { ok: true; found: true; value: SideshowdbDocumentEnvelope<IssueDocument> } {
  assert.notEqual(world.wasmResult, null, "expected a stored WASM result");
  return world.wasmResult as ReturnType<typeof getStoredResult>;
}
