import { Given, Then, When } from "@cucumber/cucumber";
import assert from "node:assert/strict";

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

When("I list documents through the CLI in summary mode", async function (this: AcceptanceWorld) {
  await executeCli(this, ["--json", "doc", "list", "--mode", "summary"]);
});

When("I request document history through the CLI in detailed mode", async function (this: AcceptanceWorld) {
  await executeCli(this, ["--json", "doc", "history", "--type", "issue", "--id", "cli-1", "--mode", "detailed"]);
});

When("I delete the document through the CLI", async function (this: AcceptanceWorld) {
  await executeCli(this, ["--json", "doc", "delete", "--type", "issue", "--id", "cli-1"]);
});

When("I run the CLI with invalid put arguments", async function (this: AcceptanceWorld) {
  await executeCli(this, ["doc", "put", "--type"]);
});

Then("the CLI command succeeds", function (this: AcceptanceWorld) {
  assert.equal(this.cliExitCode, 0, `expected CLI success, stderr was:\n${this.cliStderr}`);
});

Then("the CLI command fails with exit code {int}", function (this: AcceptanceWorld, exitCode: number) {
  assert.equal(this.cliExitCode, exitCode, `stdout:\n${this.cliStdout}\nstderr:\n${this.cliStderr}`);
});

Then("the CLI stderr contains {string}", function (this: AcceptanceWorld, text: string) {
  assert.match(this.cliStderr, new RegExp(escapeRegExp(text)));
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

async function executeCli(
  world: AcceptanceWorld,
  args: string[],
  input = "",
): Promise<void> {
  assert.ok(world.repoDir, "expected a temporary CLI repository to be created first");
  const result = await runCli(world.repoDir, args, input);
  assignCliResult(world, result);
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

function escapeRegExp(text: string): string {
  return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
