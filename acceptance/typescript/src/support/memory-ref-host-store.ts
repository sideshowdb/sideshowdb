import type { SideshowDbHostStore } from "@sideshowdb/core";

const memoryStoreStateSymbol = Symbol("memory-ref-host-store-state");

type VersionedValue = {
  version: string;
  value: string;
};

export type MemoryRefHostStoreState = {
  store: Record<string, VersionedValue[]>;
  versionCounter: number;
};

type MemoryRefHostStore = SideshowDbHostStore & {
  [memoryStoreStateSymbol]: MemoryRefHostStoreState;
};

export function createMemoryRefHostStore(
  state: MemoryRefHostStoreState = createEmptyMemoryRefHostStoreState(),
): SideshowDbHostStore {
  const store: MemoryRefHostStore = {
    [memoryStoreStateSymbol]: state,
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

  return store;
}

export function createEmptyMemoryRefHostStoreState(): MemoryRefHostStoreState {
  return {
    store: {},
    versionCounter: 0,
  };
}

export function getMemoryRefHostStoreState(
  store: SideshowDbHostStore | undefined,
): MemoryRefHostStoreState | undefined {
  if (store === undefined) {
    return undefined;
  }

  return (store as Partial<MemoryRefHostStore>)[memoryStoreStateSymbol];
}
