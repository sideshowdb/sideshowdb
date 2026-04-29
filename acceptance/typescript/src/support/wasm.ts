import { execFile } from "node:child_process";
import { promisify } from "node:util";

import type {
  GetSuccess,
  OperationFailure,
  OperationSuccess,
  SideshowdbCoreClient,
  SideshowdbDeleteRequest,
  SideshowdbDeleteResult,
  SideshowdbDocumentEnvelope,
  SideshowdbHistoryRequest,
  SideshowdbHistoryResult,
  SideshowdbListRequest,
  SideshowdbListResult,
  SideshowdbPutRequest,
  SideshowdbRefHostBridge,
} from "@sideshowdb/core";

import {
  createEmptyMemoryRefHostBridgeState,
  getMemoryRefHostBridgeState,
  type MemoryRefHostBridgeState,
} from "./memory-ref-host-bridge.js";

const execFileAsync = promisify(execFile);
const acceptanceWorkspaceUrl = new URL("../../", import.meta.url);

type WasmOperationName = "meta" | "put" | "get" | "list" | "delete" | "history";

type WasmInvocationPayload = {
  operation: WasmOperationName;
  request?: unknown;
  bridgeState?: MemoryRefHostBridgeState;
};

type WasmInvocationResponse = {
  result: unknown;
  bridgeState?: MemoryRefHostBridgeState;
};

type WasmMetadata = {
  banner: string;
  version: string;
};

export async function loadAcceptanceWasmClient(
  hostBridge?: SideshowdbRefHostBridge,
): Promise<SideshowdbCoreClient> {
  const bridgeState =
    hostBridge === undefined
      ? undefined
      : getMemoryRefHostBridgeState(hostBridge) ?? createEmptyMemoryRefHostBridgeState();
  const metadataResponse = await invokeWasm({
    operation: "meta",
    bridgeState,
  });
  const metadata = metadataResponse.result as WasmMetadata;

  return createProxyClient(metadata, bridgeState);
}

function createProxyClient(
  metadata: WasmMetadata,
  bridgeState?: MemoryRefHostBridgeState,
): SideshowdbCoreClient {
  let currentBridgeState = bridgeState;

  async function call<TResult>(
    operation: Exclude<WasmOperationName, "meta">,
    request: unknown,
  ): Promise<TResult> {
    const response = await invokeWasm({
      operation,
      request,
      bridgeState: currentBridgeState,
    });

    currentBridgeState = response.bridgeState;
    return response.result as TResult;
  }

  return {
    banner: metadata.banner,
    version: metadata.version,
    put<T = unknown>(
      request: SideshowdbPutRequest<T>,
    ): Promise<OperationSuccess<SideshowdbDocumentEnvelope<T>> | OperationFailure> {
      return call("put", request);
    },
    get<T = unknown>(
      request: Parameters<SideshowdbCoreClient["get"]>[0],
    ): Promise<GetSuccess<SideshowdbDocumentEnvelope<T>> | OperationFailure> {
      return call("get", request);
    },
    list<T = unknown>(
      request: SideshowdbListRequest,
    ): Promise<OperationSuccess<SideshowdbListResult<T>> | OperationFailure> {
      return call("list", request);
    },
    delete(
      request: SideshowdbDeleteRequest,
    ): Promise<OperationSuccess<SideshowdbDeleteResult> | OperationFailure> {
      return call("delete", request);
    },
    history<T = unknown>(
      request: SideshowdbHistoryRequest,
    ): Promise<OperationSuccess<SideshowdbHistoryResult<T>> | OperationFailure> {
      return call("history", request);
    },
  };
}

async function invokeWasm(
  payload: WasmInvocationPayload,
): Promise<WasmInvocationResponse> {
  const { stdout } = await execFileAsync("bun", ["--eval", buildWasmRunnerScript()], {
    cwd: acceptanceWorkspaceUrl,
    env: {
      ...process.env,
      SIDESHOWDB_WASM_PAYLOAD: JSON.stringify(payload),
    },
    maxBuffer: 1024 * 1024,
  });

  return JSON.parse(stdout) as WasmInvocationResponse;
}

function buildWasmRunnerScript(): string {
  return `
    import { readFile } from "node:fs/promises";
    import { loadSideshowdbClient } from "@sideshowdb/core";

    const payload = JSON.parse(process.env.SIDESHOWDB_WASM_PAYLOAD ?? "{}");
    const bytes = await readFile(process.cwd() + "/../../zig-out/wasm/sideshowdb.wasm");
    const bridgeState = payload.bridgeState;
    const hostBridge = bridgeState
      ? {
          put(key, value) {
            bridgeState.versionCounter += 1;
            const version = "v" + bridgeState.versionCounter;
            const history = bridgeState.store[key] ?? [];
            history.unshift({ version, value });
            bridgeState.store[key] = history;
            return version;
          },
          get(key, version) {
            const history = bridgeState.store[key] ?? [];
            if (version === undefined) {
              const latest = history[0];
              return latest ? { value: latest.value, version: latest.version } : null;
            }

            const match = history.find((entry) => entry.version === version);
            return match ? { value: match.value, version: match.version } : null;
          },
          delete(key) {
            delete bridgeState.store[key];
          },
          list() {
            return Object.keys(bridgeState.store).sort();
          },
          history(key) {
            return (bridgeState.store[key] ?? []).map((entry) => entry.version);
          },
        }
      : undefined;
    const client = await loadSideshowdbClient({
      wasmPath: "/fixtures/sideshowdb.wasm",
      hostBridge,
      fetchImpl: async () => ({
        ok: true,
        arrayBuffer: async () =>
          bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength),
      }),
    });

    let result;
    switch (payload.operation) {
      case "meta":
        result = { banner: client.banner, version: client.version };
        break;
      case "put":
        result = await client.put(payload.request);
        break;
      case "get":
        result = await client.get(payload.request);
        break;
      case "list":
        result = await client.list(payload.request);
        break;
      case "delete":
        result = await client.delete(payload.request);
        break;
      case "history":
        result = await client.history(payload.request);
        break;
      default:
        throw new Error("unsupported wasm operation: " + payload.operation);
    }

    process.stdout.write(JSON.stringify({ result, bridgeState }));
  `;
}
