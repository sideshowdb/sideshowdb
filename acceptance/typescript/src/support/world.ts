import { setWorldConstructor, World } from "@cucumber/cucumber";

type CliJson = Record<string, unknown> | null;
type WasmClient = Record<string, unknown> | null;
type WasmResult = Record<string, unknown> | null;
type IndexedDbState = Record<string, unknown> | null;

export class AcceptanceWorld extends World {
  repoDir: string | null = null;
  cliStdout = "";
  cliStderr = "";
  cliExitCode: number | null = null;
  cliJson: CliJson = null;
  wasmClient: WasmClient = null;
  wasmResult: WasmResult = null;
  indexedDbState: IndexedDbState = null;
}

setWorldConstructor(AcceptanceWorld);
