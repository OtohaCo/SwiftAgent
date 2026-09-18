# SwiftAgent Independent Repository Extraction

last-verified: 2026-09-18
status: Preparation complete. Independent GitHub repository not created.

Working name: **SwiftAgent**. Do not rename modules until a name is confirmed.

## Clean extraction test

On 2026-09-18 this tree was copied to `/tmp/swift-agent-extraction-test`
without the Tingting root, without `.build`, and without Xcode projects.

```sh
rsync -a --exclude '.build' --exclude '.swiftpm' SwiftAgent/ /tmp/swift-agent-extraction-test/
cd /tmp/swift-agent-extraction-test
swift package resolve
swift build
swift test --disable-sandbox --no-parallel
swift build --triple arm64-apple-ios16.0
```

Result: **PASS**. `swift test` does not need Tingting, Otoha, kanban, or repo-root
scripts.

## Repo-root coupling found

| Coupling | Impact | Action |
| --- | --- | --- |
| `SwiftAgent/README.md` linked to `../docs/guides` and `../docs/plans` | Docs lived in Tingting | Copied SDK guides into `SwiftAgent/docs/` |
| Tingting Xcode `XCLocalSwiftPackageReference "../SwiftAgent"` | Host integration | Keep until remote package exists |
| `Tingting/DEVELOPMENT.md` links | Developer entry | Point at both locations during overlap |
| Otoha EngineAdapter | Host only | Stays in Tingting |
| CryptoKit in WorkspaceAgent | Linux `swift test` of the full package | See blockers |
| FoundationModels in AgentAppleProvider | Needs Apple SDK | Separate CI job; `canImport` already isolates Core |
| No `LICENSE` / `.gitignore` / CI in the package | Independent repo metadata | Added in this preparation |

No relative SwiftPM dependency, no Tingting target import, and no shared
generated source. ArchitectureTests already forbid Otoha/Tingting tokens in
portable modules.

## Target directory structure

Keep the current layout. Do not move files to match a sketch.

```text
SwiftAgent/
├── Package.swift
├── README.md
├── LICENSE
├── CONTRIBUTING.md
├── .gitignore
├── .github/workflows/ci.yml
├── Sources/
│   ├── AgentModels/
│   ├── AgentTools/
│   ├── AgentCore/
│   ├── AgentProviders/
│   ├── AgentAppleProvider/
│   └── WorkspaceAgent/
├── Tests/
│   ├── AgentModelsTests/
│   ├── AgentToolsTests/
│   ├── AgentCoreTests/
│   ├── AgentProvidersTests/
│   ├── AgentAppleProviderTests/
│   ├── WorkspaceAgentTests/
│   └── ArchitectureTests/
└── docs/
    ├── security-model.md
    ├── extraction.md
    ├── adr/0001-workspace-agent-placement.md
    ├── guides/
    └── reviews/
```

`Documentation.docc` and `Examples/` are not required for extraction. Add them
later if DocC catalogs or extra samples need a home. WorkspaceAgent is the
reference sample.

## WorkspaceAgent

See [ADR 0001](adr/0001-workspace-agent-placement.md). Keep the SwiftPM product
`WorkspaceAgent` as Generality Proof / Reference Host. It is not Core SDK.

## Otoha

Otoha profiles, music tools, playback tools, MusicKit, conversation session,
prompts, and domain Evidence stay in Tingting. The independent repository is
the generic engine only.

## Provider packaging

Keep:

- `AgentProviders`: Anthropic + HTTP transport. `FoundationNetworking` is
  `canImport`-gated. No heavy SDK.
- `AgentAppleProvider`: Foundation Models, separate product so Core/Linux
  users do not link it.

Do not split `AnthropicProvider` / `OpenAIProvider` until a provider adds a
heavy dependency or a hard platform tax. OpenAI-compatible hosts currently live
in Tingting transports.

## Security model

[docs/security-model.md](security-model.md)

## CI matrix

Primary compiler: **Swift 6.4**. Jobs must print the compiler and fail if it is
not 6.4. `// swift-tools-version: 6.0` is the Package.swift manifest floor, not
the CI toolchain.

Apple jobs also print `xcodebuild -version` and SDK versions.

Tingting cannot see `SwiftAgent/.github/workflows/`. Until the independent
repository exists, `.github/workflows/swift-agent.yml` at the Tingting root
runs the same scripts.

| Job | Command | Live models |
| --- | --- | --- |
| macOS | `Scripts/ci-macos.sh`: `swift build`, `swift test`, iOS triple, ExternalClient | No |
| Linux | Install Swift 6.4 (release, or `6.4.x-snapshot` if no release), `swift build --target` Core modules, then `swift test` and ExternalClient | No |
| Apple provider | `Scripts/ci-apple-provider.sh` | No. `SWIFT_AGENT_APPLE_LIVE` stays operator-opt-in |

Local Linux proof (2026-09-18): Ubuntu 24.04 Docker, Swift 6.4
(`swift-6.4-RELEASE`) installed with Swiftly, `Scripts/ci-linux.sh` exit 0.
`--target` Core builds did not emit WorkspaceAgent or AgentAppleProvider
modules. `swift test` ran Core (including journal, cancellation, recovery),
WorkspaceAgent (swift-crypto), Architecture, and the ExternalClient package.

The official `swift:6.4` Docker Hub tag did not exist at this date. CI installs
the compiler with Swiftly and fails if `swift --version` is not 6.4. GitHub
hosted runners still have to execute `.github/workflows/swift-agent.yml` after
this lands.

WorkspaceAgent SHA-256 uses `apple/swift-crypto` (`Crypto`) so Linux can compile
the Reference Host. AgentCore does not take that dependency.

GitHub-hosted runners may not run Foundation Models. Fixture and compile tests
are the CI contract. There is no Swift 6.0.3 job; older compilers are not a
supported CI axis.

## Tingting dependency migration

Do not switch production Tingting to a tagged 1.0 in this step.

Recommended sequence:

1. Create `chainbow/SwiftAgent` (not done in this preparation).
2. Independent CI green on that repository.
3. Keep Tingting on the local path during overlap:

   ```swift
   XCLocalSwiftPackageReference "../SwiftAgent"
   ```

4. Development override after the remote exists:

   ```swift
   .package(url: "https://github.com/chainbow/SwiftAgent.git", branch: "main")
   ```

   Xcode: File → Add Package Dependencies, then add a local override to the
   sibling checkout. Do not require a release for every engine edit.

5. Pre-1.0 pin: branch or revision, not `from: "1.0.0"`.
6. Tingting full regression (Otoha + WorkspaceAgent tests + macOS/iOS builds).
7. Both CIs green.
8. Delete the embedded `SwiftAgent/` directory from Tingting.

Avoid a window where Tingting has neither a local tree nor a working remote.

## Repository name candidates

Suggestions only. Do not rename modules yet.

1. **SwiftAgent** — current working name, matches the package
2. **AgentKitSwift** — closer to a toolkit product name
3. **SwiftAgentRuntime** — emphasizes loop/runtime, not a full app
4. **ChainbowAgent** — org-branded, weaker as an open SDK
5. **AgentCoreSwift** — collides with the `AgentCore` module name

## 1.0 RC readiness

Ready for `1.0.0-rc.1` engineering work after the remote repository exists and
Linux Swift 6.4 CI is green on GitHub. Not ready to tag `1.0.0` or merge `main`.

## Blockers before creating the remote repository

1. Confirm the repository name with the owner.
2. Confirm GitHub org permission to create `chainbow/SwiftAgent` (or the chosen
   name). This preparation did not create it.
3. GitHub-hosted Linux Swift 6.4 job must go green after this workflow lands.
   Local Docker already ran `Scripts/ci-linux.sh` with Swift 6.4 RELEASE.
4. Decide LICENSE copyright holder text if ChainBow is not the final imprint.
5. Keep Tingting `project.pbxproj` local-package path until step 4 of the
   migration.

## Next action

Create the independent repository from `SwiftAgent/` only after name and org
permission are confirmed. Push the extracted tree, enable the CI workflow,
then change Tingting to a Git dependency with a local override. Do not delete
the embedded package until that CI is green.
