type StoredVersion = {
  version: string
  value: string
}

export function createDemoRefHostBridge() {
  const latest = new Map<string, string>()
  const versions = new Map<string, StoredVersion[]>()
  let nextVersion = 0

  const makeVersion = () => `mem-${++nextVersion}`

  return {
    put(key: string, value: string) {
      const version = makeVersion()
      const history = versions.get(key) ?? []

      history.unshift({ version, value })
      versions.set(key, history)
      latest.set(key, version)

      return version
    },
    get(key: string, version?: string) {
      const history = versions.get(key) ?? []

      if (!version) {
        const live = history.find((entry) => entry.version === latest.get(key))
        return live ? { value: live.value, version: live.version } : null
      }

      const match = history.find((entry) => entry.version === version)
      return match ? { value: match.value, version: match.version } : null
    },
    delete(key: string) {
      latest.delete(key)
    },
    list() {
      return [...latest.keys()].sort()
    },
    history(key: string) {
      return (versions.get(key) ?? []).map((entry) => entry.version)
    },
  }
}
