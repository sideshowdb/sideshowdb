const decoder = new TextDecoder()

type SideshowdbWasmExports = WebAssembly.Exports & {
  memory: WebAssembly.Memory
  sideshowdb_banner_ptr: () => number
  sideshowdb_banner_len: () => number
  sideshowdb_version_major: () => number
  sideshowdb_version_minor: () => number
  sideshowdb_version_patch: () => number
}

export type SideshowdbWasmRuntime = {
  banner: string
  version: string
}

let cachedRuntime: Promise<SideshowdbWasmRuntime> | null = null

function readUtf8(memory: WebAssembly.Memory, ptr: number, len: number): string {
  const bytes = new Uint8Array(memory.buffer, ptr, len)
  return decoder.decode(bytes)
}

function hostRefUnavailable(): number {
  return 1
}

const imports = {
  env: {
    sideshowdb_host_ref_put: hostRefUnavailable,
    sideshowdb_host_ref_get: hostRefUnavailable,
    sideshowdb_host_result_ptr: () => 0,
    sideshowdb_host_result_len: () => 0,
    sideshowdb_host_version_ptr: () => 0,
    sideshowdb_host_version_len: () => 0,
  },
}

export async function loadSideshowdbWasm(
  wasmPath: string,
): Promise<SideshowdbWasmRuntime> {
  if (!cachedRuntime) {
    cachedRuntime = (async () => {
      const response = await fetch(wasmPath)

      if (!response.ok) {
        throw new Error('The SideshowDB WASM runtime is unavailable right now.')
      }

      const bytes = await response.arrayBuffer()
      const { instance } = await WebAssembly.instantiate(bytes, imports)
      const exports = instance.exports as SideshowdbWasmExports

      const banner = readUtf8(
        exports.memory,
        exports.sideshowdb_banner_ptr(),
        exports.sideshowdb_banner_len(),
      )

      return {
        banner,
        version: `${exports.sideshowdb_version_major()}.${exports.sideshowdb_version_minor()}.${exports.sideshowdb_version_patch()}`,
      }
    })()
  }

  return cachedRuntime
}
