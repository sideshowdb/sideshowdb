import { Given, Then, When, type DataTable } from "@cucumber/cucumber";
import assert from "node:assert/strict";
import { writeFile } from "node:fs/promises";
import { join } from "node:path";

import { runCli, createTemporaryGitRepo, type CliRunResult } from "../support/cli.js";
import { AcceptanceWorld } from "../support/world.js";

Given("a temporary git-backed CLI repository", async function (this: AcceptanceWorld) {
  this.repoDir = await createTemporaryGitRepo();
  this.cliExitCode = null;
  this.cliStdout = "";
  this.cliStderr = "";
  this.cliJson = null;
});

When("I put the first document version through the CLI", async function (this: AcceptanceWorld) {
  await executeCli(this, ["--json", "doc", "put", "--type", "issue", "--id", "cli-1"], '{"title":"first"}');
});

When("I put the second document version through the CLI", async function (this: AcceptanceWorld) {
  await executeCli(this, ["--json", "doc", "put", "--type", "issue", "--id", "cli-1"], '{"title":"second"}');
});

When("I get the document through the CLI", async function (this: AcceptanceWorld) {
  await executeCli(this, ["--json", "doc", "get", "--type", "issue", "--id", "cli-1"]);
});

When(
  "I get document {string} of type {string} in namespace {string} through the CLI",
  async function (this: AcceptanceWorld, id: string, type: string, namespace: string) {
    await executeCli(
      this,
      ["--json", "doc", "get", "--namespace", namespace, "--type", type, "--id", id],
    );
  },
);

When(
  "I put document {string} of type {string} in namespace {string} through the CLI with JSON body:",
  async function (this: AcceptanceWorld, id: string, type: string, namespace: string, docString: string) {
    await executeCli(
      this,
      [
        "--json",
        "doc",
        "put",
        "--namespace",
        namespace,
        "--type",
        type,
        "--id",
        id,
      ],
      normalizeJsonDocString(docString),
    );
  },
);

When(
  "I get document {string} of type {string} in namespace {string} at remembered version {string} through the CLI",
  async function (this: AcceptanceWorld, id: string, type: string, namespace: string, rememberedVersion: string) {
    await executeCli(
      this,
      [
        "--json",
        "doc",
        "get",
        "--namespace",
        namespace,
        "--type",
        type,
        "--id",
        id,
        "--version",
        requireRememberedValue(this, rememberedVersion),
      ],
    );
  },
);

When("I list documents through the CLI in summary mode", async function (this: AcceptanceWorld) {
  await executeCli(this, ["--json", "doc", "list", "--mode", "summary"]);
});

When(
  "I list documents through the CLI in summary mode for namespace {string} and type {string}",
  async function (this: AcceptanceWorld, namespace: string, type: string) {
    await executeCli(
      this,
      ["--json", "doc", "list", "--mode", "summary", "--namespace", namespace, "--type", type],
    );
  },
);

When("I request document history through the CLI in detailed mode", async function (this: AcceptanceWorld) {
  await executeCli(this, ["--json", "doc", "history", "--type", "issue", "--id", "cli-1", "--mode", "detailed"]);
});

When(
  "I request document history for {string} of type {string} in namespace {string} through the CLI in detailed mode",
  async function (this: AcceptanceWorld, id: string, type: string, namespace: string) {
    await executeCli(
      this,
      [
        "--json",
        "doc",
        "history",
        "--namespace",
        namespace,
        "--type",
        type,
        "--id",
        id,
        "--mode",
        "detailed",
      ],
    );
  },
);

When("I delete the document through the CLI", async function (this: AcceptanceWorld) {
  await executeCli(this, ["--json", "doc", "delete", "--type", "issue", "--id", "cli-1"]);
});

When("I run the CLI with invalid put arguments", async function (this: AcceptanceWorld) {
  await executeCli(this, ["doc", "put", "--type"]);
});

When("I run the CLI with arguments:", async function (this: AcceptanceWorld, dataTable: DataTable) {
  const args = dataTable.hashes().map((row) => row.arg);
  await executeCli(this, args);
});

Given(
  "a payload file {string} containing data title {string}",
  async function (this: AcceptanceWorld, name: string, title: string) {
    const repoDir = requireRepoDir(this);
    await writeFile(join(repoDir, name), JSON.stringify({ title }));
  },
);

When(
  "I put the document through the CLI with --data-file {string}",
  async function (this: AcceptanceWorld, name: string) {
    await executeCli(
      this,
      [
        "--json",
        "doc",
        "put",
        "--type",
        "issue",
        "--id",
        "cli-1",
        "--data-file",
        name,
      ],
    );
  },
);

When(
  "I put the document through the CLI with --data-file {string} and stdin payload data title {string}",
  async function (this: AcceptanceWorld, name: string, stdinTitle: string) {
    await executeCli(
      this,
      [
        "--json",
        "doc",
        "put",
        "--type",
        "issue",
        "--id",
        "cli-1",
        "--data-file",
        name,
      ],
      JSON.stringify({ title: stdinTitle }),
    );
  },
);

Given(
  "an event JSONL file {string} with events:",
  async function (this: AcceptanceWorld, name: string, dataTable: DataTable) {
    const repoDir = requireRepoDir(this);
    const lines = dataTable.hashes().map((row) =>
      JSON.stringify({
        event_id: row.event_id,
        event_type: row.event_type,
        namespace: "default",
        aggregate_type: "issue",
        aggregate_id: "issue-1",
        timestamp: row.timestamp,
        payload: { title: row.title },
      }),
    );
    await writeFile(join(repoDir, name), `${lines.join("\n")}\n`);
  },
);

Given(
  "an event JSON batch file {string} with events:",
  async function (this: AcceptanceWorld, name: string, dataTable: DataTable) {
    const repoDir = requireRepoDir(this);
    const events = dataTable.hashes().map((row) => ({
      event_id: row.event_id,
      event_type: row.event_type,
      namespace: "default",
      aggregate_type: "issue",
      aggregate_id: "issue-1",
      timestamp: row.timestamp,
      payload: { title: row.title },
    }));
    await writeFile(join(repoDir, name), JSON.stringify({ events }));
  },
);

Given(
  "an invalid event batch file {string} containing:",
  async function (this: AcceptanceWorld, name: string, content: string) {
    const repoDir = requireRepoDir(this);
    await writeFile(join(repoDir, name), content.trim());
  },
);

When(
  "I append events from file {string} in format {string} with expected revision {int} through the CLI",
  async function (this: AcceptanceWorld, name: string, format: string, revision: number) {
    await executeCli(this, [
      "--json",
      "event",
      "append",
      "--namespace",
      "default",
      "--aggregate-type",
      "issue",
      "--aggregate-id",
      "issue-1",
      "--expected-revision",
      String(revision),
      "--format",
      format,
      "--data-file",
      name,
    ]);
  },
);

When("I load events from revision {int} through the CLI", async function (this: AcceptanceWorld, revision: number) {
  await executeCli(this, [
    "--json",
    "event",
    "load",
    "--namespace",
    "default",
    "--aggregate-type",
    "issue",
    "--aggregate-id",
    "issue-1",
    "--from-revision",
    String(revision),
  ]);
});

When(
  "I put snapshot revision {int} up to event {string} with state:",
  async function (this: AcceptanceWorld, revision: number, upToEventId: string, state: string) {
    await executeCli(
      this,
      [
        "--json",
        "snapshot",
        "put",
        "--namespace",
        "default",
        "--aggregate-type",
        "issue",
        "--aggregate-id",
        "issue-1",
        "--revision",
        String(revision),
        "--up-to-event-id",
        upToEventId,
      ],
      normalizeJsonDocString(state),
    );
  },
);

When("I get the latest snapshot through the CLI", async function (this: AcceptanceWorld) {
  await executeCli(this, [
    "--json",
    "snapshot",
    "get",
    "--namespace",
    "default",
    "--aggregate-type",
    "issue",
    "--aggregate-id",
    "issue-1",
    "--latest",
  ]);
});

When(
  "I get snapshot at or before revision {int} through the CLI",
  async function (this: AcceptanceWorld, revision: number) {
    await executeCli(this, [
      "--json",
      "snapshot",
      "get",
      "--namespace",
      "default",
      "--aggregate-type",
      "issue",
      "--aggregate-id",
      "issue-1",
      "--at-or-before",
      String(revision),
    ]);
  },
);

Then("the CLI command succeeds", function (this: AcceptanceWorld) {
  assert.equal(this.cliExitCode, 0, `expected CLI success, stderr was:\n${this.cliStderr}`);
});

Then("the CLI command fails with exit code {int}", function (this: AcceptanceWorld, exitCode: number) {
  assert.equal(this.cliExitCode, exitCode, `stdout:\n${this.cliStdout}\nstderr:\n${this.cliStderr}`);
});

Then("the CLI stderr contains {string}", function (this: AcceptanceWorld, text: string) {
  assert.match(this.cliStderr, new RegExp(escapeRegExp(text)));
});

Then("the CLI stdout contains {string}", function (this: AcceptanceWorld, text: string) {
  assert.match(this.cliStdout, new RegExp(escapeRegExp(text)));
});

Then("the CLI stdout is empty", function (this: AcceptanceWorld) {
  assert.equal(this.cliStdout, "");
});

Then("the CLI stderr is empty", function (this: AcceptanceWorld) {
  assert.equal(this.cliStderr, "");
});

Then("the CLI stdout is not JSON", function (this: AcceptanceWorld) {
  assert.equal(this.cliJson, null, `expected non-JSON stdout, got:\n${this.cliStdout}`);
});

Then("the CLI JSON data title is {string}", function (this: AcceptanceWorld, title: string) {
  const json = requireCliJson(this);
  const data = requireObject(json.data, "data");
  assert.equal(data.title, title);
});

Then("the CLI JSON kind is {string}", function (this: AcceptanceWorld, kind: string) {
  const json = requireCliJson(this);
  assert.equal(json.kind, kind);
});

Then("the first listed document id is {string}", function (this: AcceptanceWorld, id: string) {
  const json = requireCliJson(this);
  const items = requireArray(json.items, "items");
  const first = requireObject(items[0], "items[0]");
  assert.equal(first.id, id);
});

Then("the CLI JSON items length is {int}", function (this: AcceptanceWorld, length: number) {
  const json = requireCliJson(this);
  const items = requireArray(json.items, "items");
  assert.equal(items.length, length);
});

Then("the CLI JSON deleted flag is true", function (this: AcceptanceWorld) {
  const json = requireCliJson(this);
  assert.equal(json.deleted, true);
});

Then("the CLI JSON revision is {int}", function (this: AcceptanceWorld, revision: number) {
  const json = requireCliJson(this);
  assert.equal(json.revision, revision);
});

Then("the CLI JSON contains event ids:", function (this: AcceptanceWorld, dataTable: DataTable) {
  const json = requireCliJson(this);
  const items = requireArray(json.events, "events").map((item, index) =>
    requireObject(item, `events[${index}]`),
  );
  const expectedIds = dataTable.hashes().map((row) => row.event_id);
  const actualIds = items.map((item) => requireString(item.event_id, "event_id"));
  assert.deepEqual(actualIds, expectedIds);
});

Then("I remember the CLI JSON version as {string}", function (this: AcceptanceWorld, key: string) {
  const json = requireCliJson(this);
  this.rememberedValues[key] = requireString(json.version, "version");
});

Then("the CLI JSON summary items are:", function (this: AcceptanceWorld, dataTable: DataTable) {
  const json = requireCliJson(this);
  const items = requireArray(json.items, "items").map((item, index) =>
    requireObject(item, `items[${index}]`),
  );
  const expected = dataTable.hashes();
  const actual = items.map((item) => ({
    namespace: requireString(item.namespace, "namespace"),
    type: requireString(item.type, "type"),
    id: requireString(item.id, "id"),
  }));
  assert.deepEqual(actual, expected);
});

Then("the CLI JSON history items match:", function (this: AcceptanceWorld, dataTable: DataTable) {
  const json = requireCliJson(this);
  const items = requireArray(json.items, "items").map((item, index) =>
    requireObject(item, `items[${index}]`),
  );
  const actual = items.map((item) => {
    const data = requireObject(item.data, "data");
    return {
      remembered_version: requireResolvedVersionAlias(this, item.version),
      title: requireString(data.title, "data.title"),
      namespace: requireString(item.namespace, "namespace"),
      type: requireString(item.type, "type"),
      id: requireString(item.id, "id"),
    };
  });
  assert.deepEqual(actual, dataTable.hashes());
});

Then("the CLI JSON body equals:", function (this: AcceptanceWorld, docString: string) {
  const json = requireCliJson(this);
  assert.deepEqual(json.data, JSON.parse(normalizeJsonDocString(docString)));
});

async function executeCli(
  world: AcceptanceWorld,
  args: string[],
  input = "",
): Promise<void> {
  const repoDir = requireRepoDir(world);
  const result = await runCli(repoDir, args, input);
  assignCliResult(world, result);
}

function requireRepoDir(world: AcceptanceWorld): string {
  assert.ok(world.repoDir, "expected a temporary CLI repository to be created first");
  return world.repoDir;
}

function assignCliResult(world: AcceptanceWorld, result: CliRunResult): void {
  world.cliExitCode = result.exitCode;
  world.cliStdout = result.stdout;
  world.cliStderr = result.stderr;
  world.cliJson = result.json;
}

function requireCliJson(world: AcceptanceWorld): Record<string, unknown> {
  assert.ok(world.cliJson, `expected JSON stdout, got:\n${world.cliStdout}\nstderr:\n${world.cliStderr}`);
  return world.cliJson;
}

function requireObject(value: unknown, label: string): Record<string, unknown> {
  assert.ok(value !== null && typeof value === "object" && !Array.isArray(value), `expected ${label} to be an object`);
  return value as Record<string, unknown>;
}

function requireArray(value: unknown, label: string): unknown[] {
  assert.ok(Array.isArray(value), `expected ${label} to be an array`);
  return value;
}

function requireString(value: unknown, label: string): string {
  assert.equal(typeof value, "string", `expected ${label} to be a string`);
  if (typeof value !== "string") {
    throw new Error(`expected ${label} to be a string`);
  }
  return value;
}

function requireRememberedValue(world: AcceptanceWorld, key: string): string {
  const value = world.rememberedValues[key];
  assert.equal(typeof value, "string", `expected remembered value ${key} to exist`);
  return value;
}

function requireResolvedVersionAlias(world: AcceptanceWorld, value: unknown): string {
  const version = requireString(value, "version");
  for (const [alias, remembered] of Object.entries(world.rememberedValues)) {
    if (remembered === version) {
      return alias;
    }
  }
  return version;
}

function normalizeJsonDocString(docString: string): string {
  return `${docString.trim()}\n`;
}

function escapeRegExp(text: string): string {
  return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
