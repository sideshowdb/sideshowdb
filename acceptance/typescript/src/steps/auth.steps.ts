import { Given, Then, When } from "@cucumber/cucumber";
import assert from "node:assert/strict";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { runCli } from "../support/cli.js";
import { AcceptanceWorld } from "../support/world.js";

Given("a fresh sideshowdb auth config directory", async function (this: AcceptanceWorld) {
  this.authConfigDir = await mkdtemp(join(tmpdir(), "sideshowdb-auth-"));
  this.cliExitCode = null;
  this.cliStdout = "";
  this.cliStderr = "";
  this.cliJson = null;
});

When("I invoke {string}", async function (this: AcceptanceWorld, argString: string) {
  await runAuthCli(this, argString, "");
});

When(
  "I invoke {string} with stdin {string}",
  async function (this: AcceptanceWorld, argString: string, stdin: string) {
    await runAuthCli(this, argString, decodeStdin(stdin));
  },
);

Then("the auth CLI command succeeds", function (this: AcceptanceWorld) {
  assert.equal(this.cliExitCode, 0, `expected exit 0, got ${this.cliExitCode}; stderr=${this.cliStderr}`);
});

Then("the auth CLI exit code is {int}", function (this: AcceptanceWorld, expected: number) {
  assert.equal(this.cliExitCode, expected, `stderr=${this.cliStderr}`);
});

Then(
  "the auth CLI stdout equals {string}",
  function (this: AcceptanceWorld, expected: string) {
    assert.equal(this.cliStdout, decodeStdin(expected));
  },
);

Then(
  "the auth CLI stdout contains {string}",
  function (this: AcceptanceWorld, needle: string) {
    assert.ok(
      this.cliStdout.includes(needle),
      `expected stdout to contain ${JSON.stringify(needle)}; got ${JSON.stringify(this.cliStdout)}`,
    );
  },
);

Then(
  "the auth CLI stdout does not contain {string}",
  function (this: AcceptanceWorld, needle: string) {
    assert.ok(
      !this.cliStdout.includes(needle),
      `expected stdout NOT to contain ${JSON.stringify(needle)}; got ${JSON.stringify(this.cliStdout)}`,
    );
  },
);

Then(
  "the auth CLI stderr contains {string}",
  function (this: AcceptanceWorld, needle: string) {
    assert.ok(
      this.cliStderr.includes(needle),
      `expected stderr to contain ${JSON.stringify(needle)}; got ${JSON.stringify(this.cliStderr)}`,
    );
  },
);

async function runAuthCli(world: AcceptanceWorld, argString: string, stdin: string) {
  const args = argString.split(/\s+/).filter((s) => s.length > 0);
  const repoDir = world.repoDir ?? process.cwd();
  const env: Record<string, string> = {};
  if (world.authConfigDir != null) env.SIDESHOWDB_CONFIG_DIR = world.authConfigDir;
  const result = await runCli(repoDir, args, stdin, env);
  world.cliExitCode = result.exitCode;
  world.cliStdout = result.stdout;
  world.cliStderr = result.stderr;
  world.cliJson = result.json;
}

function decodeStdin(value: string): string {
  return value.replace(/\\n/g, "\n").replace(/\\t/g, "\t").replace(/\\r/g, "\r");
}
