# Claude Fable 5.1 SAI-055 Independent Review Prompt

Date: 2026-09-19
Repository: `OtohaPlayer/SwiftAgent`
Branch: `plan/swift-agent-rc2`
Reviewed commit: `a7f76c1096e1bbb310c2d6702d6cfec850187db9`
Baseline: `d139e5d74bdb746a28b8fdf3a44c593502b44fc6`

You are the independent reviewer for SAI-055, Decision Provider Contract and
Jev Adapter. State the exact model shown by your runtime at the start of the
response. Review the exact commit above in `/Users/lilong/Works/Tingting/SwiftAgent`.
Do not modify files, commit, push, or review an uncommitted working tree.

Read the complete baseline-to-reviewed diff and the relevant surrounding code,
including:

- `Package.swift`
- `Sources/AgentDecisions/`
- `Sources/AgentJevProvider/`
- `Tests/AgentDecisionsTests/`
- `Tests/AgentJevProviderTests/`
- `Tests/ArchitectureTests/`
- `Examples/JevDecision/`
- `Examples/ExternalClient/`
- `Sources/AgentModels/OperationDeadline.swift`
- `Sources/AgentModels/JSONValue.swift`
- `docs/designs/2026-09-19-decision-provider-jev.md`
- `docs/guides/swift-agent-decisions.md`
- `docs/security-model.md`

Review as a Swift SDK architect, Swift 6 concurrency reviewer, security
reviewer, HTTP adapter reviewer, and public API reviewer. Check especially:

1. Whether `DecisionProvider` is correctly separated from `ModelProvider` and
   AgentCore, and whether any decision can bypass ToolPolicy, Evidence,
   authorization, durable mutation intent, Receipt validation, or Journal
   settlement.
2. Public API semantics and stability for Noul, Choice, Score, request,
   response, usage, descriptors, deadlines, and errors. Identify APIs likely
   to be regretted after 1.0.
3. Validation completeness: empty/duplicate/unsafe identities, Codable bypass,
   missing or extra answers, answer-kind mismatch, choice membership, score
   indices and legend identity, finite/range checks, usage, safe metadata, and
   supported JSON content.
4. Jev request/response mapping against the protocol evidence recorded in the
   design, without inventing undocumented probability-sum tolerance.
5. Credential and data safety: API-key exposure through errors, descriptions,
   reflection, redirects, caching, cookies, credentials, request IDs, response
   bodies, endpoint configuration, and examples.
6. Cancellation and deadline ownership, late completion, continuation safety,
   URLSession lifecycle, Sendable correctness, locks, and task leaks.
7. HTTP status and Retry-After classification, hidden retry behavior, Linux
   portability, dependency direction, architecture guards, and ExternalClient
   coverage.
8. Whether tests genuinely prove observable behavior and include the important
   negative cases, rather than restating implementation details.
9. Documentation and public symbol inventory consistency.

Report findings first, ordered by severity: P0, P1, P2, P3. For every finding
include exact file and line, the concrete failure or misuse scenario, impact,
and a minimal recommended fix. Distinguish confirmed defects from questions or
architecture suggestions. Do not manufacture findings. If no actionable issue
exists at a severity, say so explicitly.

Finish with:

- P0/P1/P2/P3 counts.
- A direct verdict: `BLOCKING`, `NON-BLOCKING FINDINGS`, or `CLEAN`.
- Whether the security boundary remains intact.
- Whether the public API is suitable to carry into the next RC.
