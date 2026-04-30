# Git Ref Storage — Functional Spec (MVP)

## 1. Purpose & Scope

This spec describes the **first concrete subsystem** of sideshowdb: a tiny
key/value store whose **physical home is a single Git ref**. It is the lowest
useful primitive on the path to the larger
[event-sourced design](./sideshowdb-spec.md): once we can put bytes in a Git
ref under a namespace we control and read them back, we can build event logs,
snapshots, and projections on top.

The first document-oriented slice built on top of this primitive is specified
in [document-read-write-ears.md](./document-read-write-ears.md).

This document covers:

- The conceptual storage model (what lives under the ref).
- The MVP operations and their semantics.
- The implementation strategy used by `GitRefStore` (subprocess-driven git
  plumbing).
- The Zig abstraction pattern used for the `RefStore` interface, with a
  side-by-side comparison to Scala 3 traits for readers coming from Scala.

It explicitly **does not** cover: events, replay, snapshots, projections,
multi-writer atomicity, or remote sync. Those are downstream layers.

---

## 2. Storage Model

### 2.1 The ref as a controlled section

A sideshowdb store is **one Git ref**. By convention the ref lives under the
`refs/sideshowdb/` namespace:

```text
refs/sideshowdb/<section-name>
```

Examples:

```text
refs/sideshowdb/events
refs/sideshowdb/snapshots
refs/sideshowdb/projections.documents
```

Each ref points to a Git **commit object**. The commit's tree is the
"section" we own — sideshowdb is the only writer for that tree. Putting
data in `refs/sideshowdb/foo` cannot collide with the user's `refs/heads/*`,
`refs/tags/*`, or third-party refs like `refs/notes/*`.

### 2.2 Key/value mapping

Inside that tree, sideshowdb treats Git as a flat-ish key/value store:

| Concept            | Git mapping                                                            |
| ------------------ | ---------------------------------------------------------------------- |
| Section            | The ref itself (`refs/sideshowdb/<section-name>`).                     |
| Key                | A path inside the tree (e.g. `events/issue-9f3a/000123.json`).         |
| Value              | The blob at that path.                                                 |
| Whole-section snap | The tree SHA the ref currently points at.                              |
| History            | The commit chain reachable from the ref.                               |

A key MAY contain `/` — that just becomes nested tree directories. There is
no length limit beyond Git's own.

### 2.3 What we get for free

Because the data lives in normal Git objects:

- **Content addressing.** Identical values dedupe automatically.
- **Cheap snapshots.** Every write produces a new commit; the previous tree
  SHA is the previous snapshot.
- **`git diff` / `git log` work** on the section's history without any
  custom tooling.
- **`git push` / `git fetch` over the ref** moves the section between
  machines.

### 2.4 Invariants

1. The tree under `refs/sideshowdb/<section>` is **owned exclusively** by
   sideshowdb. Hand-edits invalidate caller assumptions.
2. Every write is **a new commit** — the ref is never moved sideways onto a
   foreign tree.
3. Writes never touch the working tree, the user's index, `HEAD`, or any
   other ref.
4. Read operations are pure: they may not create commits or modify refs.

---

## 3. Logical Operations

The MVP exposes four operations. They are intentionally small enough to fit
on one screen.

```text
put(key, value) → PutResult — overwrite-or-create the blob at `key`.
get(key) → value?      — return the blob bytes, or null if absent.
delete(gpa, key)       — remove the blob; idempotent if missing (`gpa` matches other `RefStore` methods).
list() → [key]         — every key currently under the section.
```

Out of scope for MVP (tracked in follow-up work):

- Optimistic concurrency control (compare-and-swap on the ref).
- Batched writes (one commit per N puts).
- Iteration with prefix filters.
- Streaming reads for large values.
- Custom commit metadata (author, message templates, signatures).

---

## 4. Implementation Strategy

### 4.1 Why subprocess plumbing first

The MVP shells out to the user's installed `git` binary using its low-level
"plumbing" commands. This buys us:

- **Correctness for free.** Git's object model, locking, and ref atomicity
  are battle-tested.
- **Zero new dependencies.** No libgit2 vendoring, no FFI, no allocator
  fights with a C library.
- **Trivially auditable.** Every operation maps to a command you can run by
  hand to debug.

A future iteration can swap the subprocess driver for a libgit2 / native
Zig backend behind the same `RefStore` interface.

### 4.2 Plumbing commands used

| Operation     | Plumbing                                                                                   |
| ------------- | ------------------------------------------------------------------------------------------ |
| Resolve ref   | `git rev-parse <ref>` and `git rev-parse <ref>^{tree}` (existence + current tree SHA).     |
| Hash a value  | `git hash-object -w <path>` — writes a blob and prints its SHA.                            |
| Build a tree  | `git read-tree <tree>` + `git update-index --add --cacheinfo 100644,<sha>,<key>` against an isolated index, then `git write-tree`. |
| Make a commit | `git commit-tree <tree> [-p <parent>] -m <msg>`.                                           |
| Move the ref  | `git update-ref <ref> <new-commit> [<old-commit>]`.                                        |
| Read a value  | `git cat-file -p <ref>:<key>`.                                                             |
| Enumerate     | `git ls-tree --name-only -r <ref>`.                                                        |

### 4.3 Why an isolated index file

`git update-index` mutates the index. The user's working index lives at
`.git/index` and is sacred — sideshowdb must not stomp on it.

The MVP sets `GIT_INDEX_FILE=<repo>/.git/sideshowdb-tmp-<random>.idx` for the
duration of a single `put`/`delete`. The temp index is read-tree'd from the
section's existing tree (or starts empty), receives the change, gets
written out as a tree, and is deleted. The user's real index is never
touched.

### 4.4 Authoring commits

Each `put` and `delete` produces one commit. The MVP fixes
`GIT_AUTHOR_NAME=sideshowdb`, `GIT_AUTHOR_EMAIL=sideshowdb@local`, and the
matching committer values via the child process environment. This makes
commits attributable and lets tests run without touching `git config`.

### 4.5 Failure modes

| Failure                    | Behavior                                                                       |
| -------------------------- | ------------------------------------------------------------------------------ |
| `git` not on `PATH`        | The first plumbing call returns `error.GitNotFound`.                           |
| Repo is not a Git repo     | `git rev-parse` errors propagate as `error.GitInvocationFailed` with stderr.   |
| Ref does not yet exist     | `get` returns `null`; `list` returns `[]`; `put` creates the first commit.     |
| Key does not exist on read | `get` returns `null` (not an error).                                           |
| Concurrent writer          | The losing `update-ref` will be rejected by Git. MVP surfaces this as an error; CAS is future work. |

### 4.6 Backend selection

Native SideshowDB ships two `RefStore` implementations:

- **`ZiggitRefStore`** — in-process backend that drives the on-disk Git
  layout directly via the vendored `ziggit_pkg` sources. This is the
  default `GitRefStore` on native targets.
- **`SubprocessGitRefStore`** — the subprocess plumbing implementation
  documented in §4.1–§4.5. Available as a compatibility fallback when a
  user wants Git's exact behavior, or when debugging an issue against an
  external git installation.

Both backends implement the same `RefStore` contract: identical
put/get/delete/list/history semantics, `PutResult.version` as an
opaque commit-SHA `VersionId`, and identical `error.InvalidKey`
rejection. A shared parity harness (`tests/ref_store_parity.zig`)
exercises both.

The CLI resolves a backend per command using the precedence:

1. `--refstore ziggit|subprocess`
2. `SIDESHOWDB_REFSTORE=ziggit|subprocess`
3. `[storage] refstore = "..."` in `.sideshowdb/config.toml`
4. built-in default: `ziggit`

An unknown backend name from any source fails the command before any ref
is mutated, with a `unsupported refstore` error on stderr.

---

## 5. The Zig Abstraction (for Scala-fluent readers)

### 5.1 What we want

We want one declared interface — `put` / `get` / `delete` / `list` — and
multiple swappable implementations behind it (today: `GitRefStore`; later:
libgit2-backed, in-memory test double, IndexedDB shim for browsers, etc.).
In Scala 3 this is the bread-and-butter case for a `trait`. Zig has no
`trait` keyword, so we build the same thing by hand using a small,
predictable pattern.

### 5.2 The Zig pattern in one paragraph

A Zig "interface" is a **plain struct** that holds a type-erased pointer to
the implementation plus a pointer to a vtable. Each method on the interface
struct just forwards to the corresponding function pointer in the vtable,
passing the erased pointer back so the implementation can recover its
concrete state. The implementation provides a small constructor that fills
in the vtable and the pointer. This is exactly how `std.mem.Allocator`,
`std.Io.Reader`, and `std.Io.Writer` are built — sideshowdb follows the
same convention so it feels native to anyone who knows the standard
library.

### 5.3 The pattern, schematically

```zig
// The "interface" — a fat pointer to whatever concrete impl is behind it.
pub const RefStore = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        put:    *const fn (ctx: *anyopaque, gpa: Allocator, key: []const u8, value: []const u8) anyerror!PutResult,
        get:    *const fn (ctx: *anyopaque, gpa: Allocator, key: []const u8) anyerror!?[]u8,
        delete: *const fn (ctx: *anyopaque, key: []const u8) anyerror!void,
        list:   *const fn (ctx: *anyopaque, gpa: Allocator) anyerror![][]u8,
    };

    // Convenience methods that hide the vtable from callers.
    pub fn put(self: RefStore, gpa: Allocator, key: []const u8, value: []const u8) anyerror!PutResult {
        return self.vtable.put(self.ptr, gpa, key, value);
    }
    // ... and so on for get / delete / list
};
```

```zig
// The implementation registers itself by handing back a RefStore.
pub const GitRefStore = struct {
    // ... fields ...

    pub fn refStore(self: *GitRefStore) RefStore {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    const vtable: RefStore.VTable = .{
        .put    = putImpl,
        .get    = getImpl,
        .delete = deleteImpl,
        .list   = listImpl,
    };

    fn putImpl(ctx: *anyopaque, gpa: Allocator, key: []const u8, value: []const u8) anyerror!RefStore.PutResult {
        const self: *GitRefStore = @ptrCast(@alignCast(ctx));
        // ... real work ...
    }
    // ... rest ...
};
```

Callers only ever speak `RefStore`:

```zig
fn append(gpa: Allocator, store: RefStore, key: []const u8, value: []const u8) !void {
    const result = try store.put(gpa, key, value);
    defer RefStore.freePutResult(gpa, result);
}
```

### 5.4 Side-by-side with Scala 3

The same idea written in Scala 3 looks roughly like this:

```scala
// Scala 3
trait RefStore:
  def put(key: String, value: Array[Byte]): PutResult
  def get(key: String): Option[Array[Byte]]
  def delete(key: String): Unit
  def list(): Seq[String]

final class GitRefStore(repoPath: Path, refName: String) extends RefStore:
  def put(key: String, value: Array[Byte]): PutResult = ???
  def get(key: String): Option[Array[Byte]]         = ???
  def delete(key: String): Unit                     = ???
  def list(): Seq[String]                           = ???

def append(store: RefStore, key: String, value: Array[Byte]): Unit =
  store.put(key, value)
```

Map the moving parts directly:

| Scala 3 concept                                 | Zig equivalent                                                                                       |
| ----------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| `trait RefStore` declaration                    | The `pub const RefStore = struct { ... }` interface struct.                                          |
| Method signatures on the trait                  | Function-pointer fields inside `RefStore.VTable`.                                                    |
| `class GitRefStore extends RefStore`            | A standalone `pub const GitRefStore = struct { ... }` with a `refStore()` method that returns a `RefStore`. |
| Concrete `def put(...)` on the class            | `fn putImpl(ctx: *anyopaque, ...)` whose first action is `@ptrCast(@alignCast(ctx))` to recover `*GitRefStore`. |
| Compiler-generated vtable                       | The hand-written `const vtable: RefStore.VTable = .{ .put = putImpl, ... }`.                         |
| `extends`                                       | The contract that your `vtable` matches `RefStore.VTable` — checked at compile time when the literal is built. |
| `store: RefStore` parameter                     | `store: RefStore` parameter (the fat-pointer struct, two machine words).                             |
| `Option[Array[Byte]]`                           | `?[]u8` (null = `None`, non-null = `Some`).                                                          |
| `???` (unimplemented)                           | `unreachable` or `return error.NotImplemented`.                                                      |

### 5.5 Differences worth flagging

A Scala dev should expect these surprises:

1. **No automatic dispatch.** Scala 3 builds the vtable for you when you say
   `extends`. In Zig you write the vtable literal yourself. The upside:
   it's just data — you can mock, swap, or inspect it.
2. **No subtyping.** A `*GitRefStore` is not a `RefStore`. You convert one
   into the other by calling `.refStore()`, which produces a fresh
   fat-pointer struct. There is no implicit upcast.
3. **Ownership is explicit.** Methods that allocate (e.g. `get`, `list`)
   take an `Allocator` and the caller frees the result. Scala's GC has no
   counterpart; treat allocator parameters as the contract you'd otherwise
   write into a Scaladoc.
4. **Errors are values.** `anyerror!void` is roughly Scala's
   `Either[Throwable, Unit]` but baked into the type system with `try` /
   `catch` syntax. There are no checked exceptions; the error union is the
   only error channel.
5. **`*anyopaque` looks scarier than it is.** Mentally translate it as
   "this method is called on `this`, but `this` has been erased". Every
   impl method's first line recovers the real `this` with two builtin
   casts.
6. **Type classes don't apply.** Scala 3 `given`/`using` (typeclass-style)
   has no direct Zig analogue. The Zig convention is to pass the
   interface struct explicitly. For sideshowdb that's exactly what we
   want — we are storing it in fields and threading it through call
   sites, not summoning it from implicit scope.

### 5.6 When NOT to use this pattern

The vtable-and-fat-pointer pattern shines when you genuinely need runtime
polymorphism — for example, the same call site choosing between a
production `GitRefStore` and a test double. If a function only ever has
one implementation, prefer plain generics (`anytype` parameters or
`comptime T`) — they monomorphize at compile time, avoid the indirect
call, and read more like a Scala generic method.

---

## 6. Acceptance Tests (informal)

The MVP is "done" when a single test, against an ephemeral repo, can:

1. Construct a `RefStore` backed by `GitRefStore`.
2. `put("a/x.txt", "hello")` — succeeds.
3. `get("a/x.txt")` — returns `"hello"`.
4. `put("a/x.txt", "world")` — succeeds (overwrite).
5. `get("a/x.txt")` — returns `"world"`.
6. `put("b/y.txt", "ok")` — succeeds.
7. `list()` — returns `{ "a/x.txt", "b/y.txt" }` (order-independent).
8. `delete("a/x.txt")` — succeeds.
9. `get("a/x.txt")` — returns `null`.
10. `git rev-list refs/sideshowdb/<section>` shows ≥ 4 commits, proving the
    history was preserved across writes.

---

## 7. Future Work (not in MVP)

- Optimistic concurrency: take an `expected_old_commit` parameter on `put`
  / `delete`, propagate it as `git update-ref <ref> <new> <old>`.
- Batch API: `withTransaction(fn)` that commits once at the end.
- Native plumbing: drop the subprocess shell-out for libgit2 or a Zig-native
  object reader.
- Integrity: optional commit signing.
- Sync layer: `pull` / `push` operations over the section's ref.
