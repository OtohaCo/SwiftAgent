# SwiftAgent Repository Provenance

last-verified: 2026-09-19
status: Extracted to `OtohaCo/SwiftAgent`

## Canonical Repository

- GitHub: `https://github.com/OtohaCo/SwiftAgent`
- SwiftPM: `https://github.com/OtohaCo/SwiftAgent.git`
- SSH: `git@github.com:OtohaCo/SwiftAgent.git`
- Default branch: `main`
- Repository visibility at extraction: private
- Current repository visibility: public

The package, repository, and module family name are frozen as **SwiftAgent**.

## Extraction Record

- Source repository: `chainbow/Tingting`
- Source branch: `plan/swift-agent-engine`
- Source SHA: `9d96070c5b362be56145e3f1701e75c737f0f880`
- Method: `git subtree split --prefix=SwiftAgent <source-sha>`
- First extracted SHA: `e6c51f3b8b6d038c96dbc501fb86cea05bd6d180`
- Repository preparation baseline: `399242dcd7ae1f5c3cfc3eac2567691fdbbf8f82`
- First independent branch: `main`

The subtree split retains SwiftAgent-related authors, timestamps, and commit
attribution while excluding unrelated Tingting files and history. The initial
remote was empty, so the first push created `main` without force-pushing or
overwriting user history.

## Independence Boundary

The repository root is the package root. Production build and runtime do not
depend on Tingting, Otoha, Xcode project files, kanban data, parent-directory
packages, or repository secrets.

`Examples/ExternalClient` intentionally uses `path: "../.."` to consume this
repository root as a separate local Swift package during tests. It is a public
API consumer fixture, not a dependency outside this repository.

Historical audit documents may mention Tingting and Otoha as the source host.
Architecture tests may contain those names as negative fixtures. Portable
production modules remain domain-neutral.

## Package Layout

- `AgentModels`: model data and provider contracts
- `AgentTools`: typed tools, policy, Evidence, receipts, and scheduling
- `AgentCore`: Agent, Session, Run, Journal, and orchestration
- `AgentProviders`: Anthropic and generic HTTP/SSE provider support
- `AgentAppleProvider`: optional Apple Foundation Models adapter
- `WorkspaceAgent`: Reference Host and generality proof, not a Core dependency

The only external Swift package dependency is `apple/swift-crypto`, used by
WorkspaceAgent. AgentCore does not depend on it.

## CI Contract

`.github/workflows/ci.yml` runs three jobs:

- macOS Swift 6.4: full package tests, iOS cross-build, ExternalClient, and the
  named concurrency seal
- Linux Swift 6.4 on Ubuntu 24.04: Core target isolation, full tests, and ExternalClient
- Apple provider compile: fixture/unit coverage without live model credentials

The concurrency seal first checks `swift test list` for 11
`ToolResourceCoordinatorTests` and 3 `AgentCompletionCommitTests`, preventing a
zero-match `swift test --filter` invocation from producing a false green result.

Hosted run `35410345928` executed all three jobs on real GitHub-hosted runners:
macOS and Apple used macOS 27.0 / Xcode 27.0 / Apple Swift 6.4, and Linux used
Ubuntu 24.04.5 / Swift 6.4. All jobs passed. The macOS concurrency seal executed
11 resource-coordinator tests and 3 completion-commit tests without skips.

The repository was private during RC preparation and became public on
2026-09-19 before `1.0.0-rc.1`. A credential-isolated anonymous HTTPS clone and
a no-cache SwiftPM consumer both resolved and built the documented `main`
dependency without GitHub authentication.

## Tingting Overlap

Tingting intentionally retains its embedded `SwiftAgent/` and local Xcode
package reference during the RC seal. Migrating Tingting to the remote package
and removing the embedded copy are separate follow-up operations after the
independent baseline is frozen.

No RC tag, GitHub Release, or Tingting production dependency migration occurred
during extraction.
