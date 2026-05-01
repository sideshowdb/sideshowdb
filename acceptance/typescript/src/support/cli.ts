import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

export type CliJson = Record<string, unknown> | null;

export interface CliRunResult {
  exitCode: number;
  stdout: string;
  stderr: string;
  json: CliJson;
}

const repoRoot = fileURLToPath(new URL("../../../../", import.meta.url));
const cliBinary = resolve(repoRoot, "zig-out/bin/sideshow");

export async function createTemporaryGitRepo(): Promise<string> {
  const repoDir = await mkdtemp(join(tmpdir(), "sideshowdb-cli-"));
  const init = await runProcess("git", ["init", "--quiet", repoDir], process.cwd(), "");

  if (init.exitCode !== 0) {
    throw new Error(`git init failed:\n${init.stderr || init.stdout}`);
  }

  const configureName = await runProcess(
    "git",
    ["-C", repoDir, "config", "user.name", "SideshowDB Acceptance"],
    process.cwd(),
    "",
  );
  if (configureName.exitCode !== 0) {
    throw new Error(`git config user.name failed:\n${configureName.stderr || configureName.stdout}`);
  }

  const configureEmail = await runProcess(
    "git",
    ["-C", repoDir, "config", "user.email", "acceptance@sideshowdb.test"],
    process.cwd(),
    "",
  );
  if (configureEmail.exitCode !== 0) {
    throw new Error(`git config user.email failed:\n${configureEmail.stderr || configureEmail.stdout}`);
  }

  return repoDir;
}

export async function runCli(
  repoDir: string,
  args: string[],
  input = "",
  envOverrides: Record<string, string> = {},
): Promise<CliRunResult> {
  const result = await runProcess(cliBinary, args, repoDir, input, envOverrides);
  return {
    exitCode: result.exitCode,
    stdout: result.stdout,
    stderr: result.stderr,
    json: parseJson(result.stdout),
  };
}

async function runProcess(
  command: string,
  args: string[],
  cwd: string,
  input: string,
  envOverrides: Record<string, string> = {},
): Promise<{ exitCode: number; stdout: string; stderr: string }> {
  return await new Promise((resolvePromise, rejectPromise) => {
    const child = spawn(command, args, {
      cwd,
      stdio: ["pipe", "pipe", "pipe"],
      env: { ...process.env, ...envOverrides },
    });

    const stdout: Buffer[] = [];
    const stderr: Buffer[] = [];

    child.stdout.on("data", (chunk: Buffer) => stdout.push(chunk));
    child.stderr.on("data", (chunk: Buffer) => stderr.push(chunk));

    child.on("error", (error: NodeJS.ErrnoException) => {
      if (error.code === "ENOENT") {
        rejectPromise(
          new Error(`required CLI binary not found at ${command}; build zig-out/bin/sideshow first`),
        );
        return;
      }

      rejectPromise(error);
    });

    child.on("close", (exitCode) => {
      resolvePromise({
        exitCode: exitCode ?? 1,
        stdout: Buffer.concat(stdout).toString("utf8"),
        stderr: Buffer.concat(stderr).toString("utf8"),
      });
    });

    if (input.length > 0) {
      child.stdin.write(input);
    }
    child.stdin.end();
  });
}

function parseJson(stdout: string): CliJson {
  const trimmed = stdout.trim();
  if (trimmed.length === 0 || (trimmed[0] !== "{" && trimmed[0] !== "[")) {
    return null;
  }

  const parsed: unknown = JSON.parse(trimmed);
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
    return null;
  }

  return parsed as Record<string, unknown>;
}
