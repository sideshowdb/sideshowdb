import type { SideshowdbRefHostBridge } from "@sideshowdb/core";

const memoryBridgeStateSymbol = Symbol("memory-ref-host-bridge-state");

type VersionedValue = {
  version: string;
  value: string;
};

export type MemoryRefHostBridgeState = {
  store: Record<string, VersionedValue[]>;
  versionCounter: number;
};

type MemoryRefHostBridge = SideshowdbRefHostBridge & {
  [memoryBridgeStateSymbol]: MemoryRefHostBridgeState;
};

export function createMemoryRefHostBridge(
  state: MemoryRefHostBridgeState = createEmptyMemoryRefHostBridgeState(),
): SideshowdbRefHostBridge {
  const bridge: MemoryRefHostBridge = {
    [memoryBridgeStateSymbol]: state,
    put(key, value) {
      state.versionCounter += 1;
      const version = `v${state.versionCounter}`;
      const history = state.store[key] ?? [];
      history.unshift({ version, value });
      state.store[key] = history;
      return version;
    },
    get(key, version) {
      const history = state.store[key] ?? [];
      if (version === undefined) {
        const latest = history[0];
        return latest ? { value: latest.value, version: latest.version } : null;
      }

      const match = history.find((entry) => entry.version === version);
      return match ? { value: match.value, version: match.version } : null;
    },
    delete(key) {
      delete state.store[key];
    },
    list() {
      return Object.keys(state.store).sort();
    },
    history(key) {
      return (state.store[key] ?? []).map((entry) => entry.version);
    },
  };

  return bridge;
}

export function createEmptyMemoryRefHostBridgeState(): MemoryRefHostBridgeState {
  return {
    store: {},
    versionCounter: 0,
  };
}

export function getMemoryRefHostBridgeState(
  bridge: SideshowdbRefHostBridge | undefined,
): MemoryRefHostBridgeState | undefined {
  if (bridge === undefined) {
    return undefined;
  }

  return (bridge as Partial<MemoryRefHostBridge>)[memoryBridgeStateSymbol];
}
