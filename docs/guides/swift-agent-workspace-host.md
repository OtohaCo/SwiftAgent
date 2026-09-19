# SwiftAgent Workspace Host

last-verified: 2026-09-19

`WorkspaceAgent` is a second Reference Host. It proves SwiftAgent can run a
sandbox file agent without product-domain types or AgentCore changes.

The host is not a product. It has no GUI, shell, git or editor. It only wires
the public engine API to five file tools.

## Construction

Automated tests use a scripted provider. The public constructor accepts any
`ModelProvider`. The bundled convenience uses Anthropic because that adapter
already conforms to the streaming contract. OpenAI is not a stable in-tree
provider yet.

```swift
import AgentCore
import AgentModels
import AgentProviders
import WorkspaceAgent

let journal = try AgentJournal(persistenceURL: journalURL)
let host = try WorkspaceAgentHost(
    root: sandboxRoot,
    provider: AnthropicProvider(apiKey: apiKey),
    model: ModelID(provider: "anthropic", name: "claude-sonnet-4-6"),
    journal: journal
)
let session = try host.makeSession()
let run = try await session.run("List the notes directory, then update todo.txt.")
_ = try await run.wait()
```

`WorkspaceAgentHost.makeTools(store:)` does not import a provider. Substitute
Anthropic, a fixture, or another conforming adapter without editing tools or
AgentCore. Share one `ToolScheduler` and one `WorkspaceFileStore` when multiple
Sessions use the same sandbox.

## Tools

| Tool | Effect | Notes |
| --- | --- | --- |
| `list_files` | read-only | Lists sandbox files and publishes directory/file Evidence |
| `read_file` | read-only | Reads one file; Evidence id is `workspace.file:<canonical path>` with a SHA-256 hash from swift-crypto `Crypto` |
| `search_files` | read-only | Searches names and UTF-8 content |
| `write_file` | mutation | Existing files require `expectedHash` as a write precondition. Receipt revision is the SHA-256 of the requested new content, including a same-content rewrite. Creates require parent-directory Evidence and fail if the target appears first. |
| `move_file` | mutation | Moves a file whose current hash matches Evidence. A destination that appears before the move is a conflict, not an overwrite. |

Paths are canonical, relative, and confined to the sandbox. `.` segments, `..`,
absolute paths, symlink escape, and symlink replacement of the root or an
intermediate directory are rejected. The host pins the authorized root's
directory identity at construction and checks the original directory entry on
later reads and writes; it does not re-resolve the root into a different
directory. There is no shell tool.

## Mutation path

The host reuses AgentJournal and ToolReceipt. A write of an existing file follows
the engine order:

1. Model proposes `write_file`
2. Schema validation
3. Evidence revalidation against the hash observed by `read_file`
4. Authorization
5. Durable mutation intent
6. Host executor writes bytes only if the on-disk hash still matches
7. `ToolReceipt` with operation id, target and the exact hash of the requested content
8. Receipt validation and durable settlement

`expectedHash` is a precondition, not a Receipt "must change" rule. Writing the
same bytes back with a valid hash must settle. The Receipt constraint is
`.exact` of the requested content. Validation is not reduced to `.present`.

If the file changes between read and write, the executor fail-closes. A missing
or mismatched receipt is not success. After a crash with a durable intent and no
trusted receipt, reload recovers `needsReconciliation` and does not replay
`write_file` or `move_file`.

## Threat model

The shared `ToolScheduler` serializes cooperative Workspace Sessions. Every
mutation on that scheduler is exclusive of every other mutation, including
writes to disjoint files. That is a collaboration contract, not protection
against an arbitrary process.

Three writers are not the same:

| Writer | What the host guarantees |
| --- | --- |
| Cooperative Sessions sharing one scheduler and one store | Mutations do not overlap. Same-file writers see each other's committed hashes. |
| A test or operator using the injected post-check barrier | Detected hash, existence, and symlink conflicts fail closed and do not publish a success Receipt. |
| An arbitrary external process | Best-effort fail-closed at the last hash or existence check, `O_EXCL` create, post-write hash verification, and a pinned root directory identity. Not a linearizable compare-and-swap. |

Atomic replace is not a hash-conditioned commit. Checking the path or hash again
does not prove the remaining window has closed. A create that loses a race must
not overwrite the file that appeared; it must throw and must not return a
success Receipt.

Unsupported: if an external writer changes an existing file after the last hash
check and before the atomic replace, this host may overwrite that writer and
then confirm its own requested bytes. The SDK does not claim to have prevented
that lost update. Conflict that is detected never settles as success.

## Architecture check

Workspace path, hash and file identity live in the host. AgentCore still only
knows generic Evidence, Receipt, resources and journal records.
