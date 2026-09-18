# SwiftAgent Workspace Host

last-verified: 2026-09-18

`WorkspaceAgent` is a second Reference Host. It proves SwiftAgent can run a
sandbox file agent without Otoha, player types, or AgentCore changes.

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
| `read_file` | read-only | Reads one file; Evidence id is `workspace.file:<canonical path>` with a CryptoKit SHA-256 hash |
| `search_files` | read-only | Searches names and UTF-8 content |
| `write_file` | mutation | Existing files require `expectedHash`; creates require parent-directory Evidence |
| `move_file` | mutation | Moves a file whose current hash matches Evidence |

Paths are canonical, relative, and confined to the sandbox. `.` segments, `..`,
absolute paths and symlink escape are rejected. There is no shell tool.

## Mutation path

The host reuses AgentJournal and ToolReceipt. A write of an existing file follows
the engine order:

1. Model proposes `write_file`
2. Schema validation
3. Evidence revalidation against the hash observed by `read_file`
4. Authorization
5. Durable mutation intent
6. Host executor writes bytes only if the on-disk hash still matches
7. `ToolReceipt` with operation id, target and resulting hash
8. Receipt validation and durable settlement

If the file changes between read and write, the executor fail-closes. A missing
or mismatched receipt is not success. After a crash with a durable intent and no
trusted receipt, reload recovers `needsReconciliation` and does not replay
`write_file` or `move_file`.

## Architecture check

Workspace path, hash and file identity live in the host. AgentCore still only
knows generic Evidence, Receipt, resources and journal records.
