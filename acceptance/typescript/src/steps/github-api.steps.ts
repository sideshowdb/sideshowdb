import assert from "node:assert/strict";

import { Given, Then, When } from "@cucumber/cucumber";

import { runCli } from "../support/cli.js";
import { AcceptanceWorld } from "../support/world.js";

// ---------------------------------------------------------------------------
// Background / setup
// ---------------------------------------------------------------------------

Given(
  "the GitHub mock server targets repo {string}",
  function (this: AcceptanceWorld, ownerRepo: string) {
    const slash = ownerRepo.indexOf("/");
    assert.ok(slash > 0, `expected owner/repo but got: ${ownerRepo}`);
    this.githubOwner = ownerRepo.slice(0, slash);
    this.githubRepo = ownerRepo.slice(slash + 1);
    this.githubMock!.reset();
    this.rememberedValues = {};
  },
);

// ---------------------------------------------------------------------------
// When — CLI operations through GitHub refstore
// ---------------------------------------------------------------------------

When(
  "I put document {string} of type {string} in namespace {string} through the GitHub CLI refstore with JSON body:",
  async function (
    this: AcceptanceWorld,
    id: string,
    type: string,
    namespace: string,
    docString: string,
  ) {
    await runGitHubCli(
      this,
      ["doc", "put", "--namespace", namespace, "--type", type, "--id", id],
      JSON.stringify(JSON.parse(docString)),
    );
  },
);

When(
  "I get document {string} of type {string} in namespace {string} through the GitHub CLI refstore",
  async function (this: AcceptanceWorld, id: string, type: string, namespace: string) {
    await runGitHubCli(this, ["doc", "get", "--namespace", namespace, "--type", type, "--id", id]);
  },
);

When(
  "I get document {string} of type {string} in namespace {string} at version {string} through the GitHub CLI refstore",
  async function (
    this: AcceptanceWorld,
    id: string,
    type: string,
    namespace: string,
    version: string,
  ) {
    await runGitHubCli(this, [
      "doc",
      "get",
      "--namespace",
      namespace,
      "--type",
      type,
      "--id",
      id,
      "--version",
      version,
    ]);
  },
);

When(
  "I get document {string} of type {string} in namespace {string} at remembered version {string} through the GitHub CLI refstore",
  async function (
    this: AcceptanceWorld,
    id: string,
    type: string,
    namespace: string,
    rememberedKey: string,
  ) {
    const version = this.rememberedValues[rememberedKey];
    assert.ok(version, `no remembered value for key: ${rememberedKey}`);
    await runGitHubCli(this, [
      "doc",
      "get",
      "--namespace",
      namespace,
      "--type",
      type,
      "--id",
      id,
      "--version",
      version,
    ]);
  },
);

When(
  "I list documents of type {string} in namespace {string} through the GitHub CLI refstore",
  async function (this: AcceptanceWorld, type: string, namespace: string) {
    await runGitHubCli(this, [
      "doc",
      "list",
      "--mode",
      "summary",
      "--namespace",
      namespace,
      "--type",
      type,
    ]);
  },
);

When(
  "I delete document {string} of type {string} in namespace {string} through the GitHub CLI refstore",
  async function (this: AcceptanceWorld, id: string, type: string, namespace: string) {
    await runGitHubCli(this, [
      "doc",
      "delete",
      "--namespace",
      namespace,
      "--type",
      type,
      "--id",
      id,
    ]);
  },
);

When(
  "I request history for document {string} of type {string} in namespace {string} through the GitHub CLI refstore",
  async function (this: AcceptanceWorld, id: string, type: string, namespace: string) {
    await runGitHubCli(this, [
      "doc",
      "history",
      "--mode",
      "summary",
      "--namespace",
      namespace,
      "--type",
      type,
      "--id",
      id,
    ]);
  },
);

When(
  "I put document {string} of type {string} in namespace {string} through the GitHub CLI refstore with no credentials",
  async function (this: AcceptanceWorld, id: string, type: string, namespace: string) {
    await runGitHubCli(
      this,
      ["doc", "put", "--namespace", namespace, "--type", type, "--id", id],
      JSON.stringify({ title: "test" }),
      {},
    );
  },
);

When(
  "the mock injects a {int} failure for the next GitHub request",
  function (this: AcceptanceWorld, status: number) {
    this.githubMock!.injectFailure({ status });
  },
);

When(
  "the mock injects a 403 rate-limit failure for the next GitHub request",
  function (this: AcceptanceWorld) {
    this.githubMock!.injectFailure({
      status: 403,
      headers: { "X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1700000000" },
      body: JSON.stringify({
        message: "API rate limit exceeded",
        documentation_url:
          "https://docs.github.com/rest/overview/resources-in-the-rest-api#rate-limiting",
      }),
    });
  },
);

// ---------------------------------------------------------------------------
// Then — assertions
// ---------------------------------------------------------------------------

Then("the CLI JSON version is a non-empty string", function (this: AcceptanceWorld) {
  const json = requireCliJson(this);
  const version = json.version;
  assert.equal(typeof version, "string", "expected version to be a string");
  assert.ok((version as string).length > 0, "expected version to be non-empty");
});

Then(
  "the mock GitHub ref {string} exists",
  function (this: AcceptanceWorld, refName: string) {
    assert.ok(
      this.githubMock!.refExists(refName),
      `expected ref ${refName} to exist in mock`,
    );
  },
);

Then("the CLI JSON list is empty", function (this: AcceptanceWorld) {
  const json = requireCliJson(this);
  const items = json.items;
  assert.ok(Array.isArray(items), "expected items to be an array");
  assert.equal((items as unknown[]).length, 0, "expected empty list");
});

Then("the CLI JSON list has {int} items", function (this: AcceptanceWorld, count: number) {
  const json = requireCliJson(this);
  const items = json.items;
  assert.ok(Array.isArray(items), "expected items to be an array");
  assert.equal((items as unknown[]).length, count);
});

Then(
  "the CLI JSON list contains ids in order:",
  function (this: AcceptanceWorld, dataTable: import("@cucumber/cucumber").DataTable) {
    const json = requireCliJson(this);
    const items = json.items as Array<Record<string, unknown>>;
    assert.ok(Array.isArray(items), "expected items to be an array");
    const expected = dataTable.hashes().map(row => row.id);
    const actual = items.map(item => item.id);
    assert.deepEqual(actual, expected);
  },
);

Then(
  "the CLI JSON history has at least {int} versions",
  function (this: AcceptanceWorld, minCount: number) {
    const json = requireCliJson(this);
    const items = json.items;
    assert.ok(Array.isArray(items), "expected items to be an array");
    assert.ok(
      (items as unknown[]).length >= minCount,
      `expected at least ${minCount} history items, got ${(items as unknown[]).length}`,
    );
  },
);

Then("the CLI JSON deleted flag is false", function (this: AcceptanceWorld) {
  const json = requireCliJson(this);
  assert.equal(json.deleted, false);
});

Then(
  "the CLI JSON data field {string} equals {string}",
  function (this: AcceptanceWorld, field: string, expected: string) {
    const json = requireCliJson(this);
    const data = json.data as Record<string, unknown>;
    assert.equal(String(data[field]), expected);
  },
);

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

async function runGitHubCli(
  world: AcceptanceWorld,
  docArgs: string[],
  input = "",
  envOverrides: Record<string, string> = { GITHUB_TOKEN: "test-token" },
): Promise<void> {
  const { githubMock, githubOwner, githubRepo, repoDir } = world;
  assert.ok(githubMock, "githubMock not initialized — missing @github tag?");
  assert.ok(repoDir, "repoDir not initialized");

  const args = [
    "--refstore",
    "github",
    "--repo",
    `${githubOwner}/${githubRepo}`,
    "--api-base",
    githubMock.url,
    "--credential-helper",
    "env",
    "--json",
    ...docArgs,
  ];

  const result = await runCli(repoDir, args, input, envOverrides);
  world.cliStdout = result.stdout;
  world.cliStderr = result.stderr;
  world.cliExitCode = result.exitCode;
  world.cliJson = result.json;
}

function requireCliJson(world: AcceptanceWorld): Record<string, unknown> {
  assert.ok(
    world.cliJson,
    `expected JSON stdout, got:\n${world.cliStdout}\nstderr:\n${world.cliStderr}`,
  );
  return world.cliJson;
}
