# SAI-071 Public API Additions

last-verified: 2026-09-20

Generated with Swift 6.4 public symbol graphs from baseline
`489c5058671452d52c6495e0716dbed69073eef2` and the SAI-071 working tree.
The graph changes from 1,295 to 1,316 precise public identifiers and from 136
to 138 top-level public types: 21 additions, 0 removals.

All additions are in `AgentProviders`. No `AgentModels`, `AgentTools`,
`AgentCore`, journal, Evidence, Receipt, or mutation API changes. The shared
canonical Responses encoder and generic stream decoder policy remain internal.

## Stability decisions

| Surface | Decision | Reason |
| --- | --- | --- |
| `LocalResponsesProvider` | KEEP | Third-party Hosts need a distinct provider whose semantics do not imply the official OpenAI service. |
| `LocalResponsesProvider.Configuration` | KEEP | Groups the required endpoint/model and conservative per-model capability declaration without growing initializer overloads. |
| `LocalResponsesAuthentication` | KEEP | The struct plus factories permits future authentication additions without expanding a public exhaustive enum. Its descriptions and reflection redact the token. |
| `model`, `descriptor`, `stream(request:)` | KEEP | Required provider identity and `ModelProvider` conformance. |
| `transport:` initializer parameter | KEEP | Matches existing provider testability and custom transport integration. |

## Added precise identifiers

| Symbol | Kind | Source | Precise identifier |
| --- | --- | --- | --- |
| `LocalResponsesAuthentication` | Structure | `LocalResponsesProvider.swift:8` | `s:14AgentProviders28LocalResponsesAuthenticationV` |
| `.none` | Type property | `LocalResponsesProvider.swift:17` | `s:14AgentProviders28LocalResponsesAuthenticationV4noneACvpZ` |
| `.bearer(_:)` | Type method | `LocalResponsesProvider.swift:19` | `s:14AgentProviders28LocalResponsesAuthenticationV6beareryACSSFZ` |
| `description` | Instance property | `LocalResponsesProvider.swift:23` | `s:14AgentProviders28LocalResponsesAuthenticationV11descriptionSSvp` |
| `debugDescription` | Instance property | `LocalResponsesProvider.swift:30` | `s:14AgentProviders28LocalResponsesAuthenticationV16debugDescriptionSSvp` |
| `customMirror` | Instance property | `LocalResponsesProvider.swift:31` | `s:14AgentProviders28LocalResponsesAuthenticationV12customMirrors0G0Vvp` |
| `LocalResponsesProvider` | Structure | `LocalResponsesProvider.swift:36` | `s:14AgentProviders22LocalResponsesProviderV` |
| `Configuration` | Nested structure | `LocalResponsesProvider.swift:38` | `s:14AgentProviders22LocalResponsesProviderV13ConfigurationV` |
| `Configuration.baseURL` | Instance property | `LocalResponsesProvider.swift:39` | `s:14AgentProviders22LocalResponsesProviderV13ConfigurationV7baseURL10Foundation0H0Vvp` |
| `Configuration.model` | Instance property | `LocalResponsesProvider.swift:40` | `s:14AgentProviders22LocalResponsesProviderV13ConfigurationV5modelSSvp` |
| `Configuration.authentication` | Instance property | `LocalResponsesProvider.swift:41` | `s:14AgentProviders22LocalResponsesProviderV13ConfigurationV14authenticationAA0cD14AuthenticationVvp` |
| `Configuration.maximumOutputTokens` | Instance property | `LocalResponsesProvider.swift:42` | `s:14AgentProviders22LocalResponsesProviderV13ConfigurationV19maximumOutputTokensSivp` |
| `Configuration.capabilities` | Instance property | `LocalResponsesProvider.swift:43` | `s:14AgentProviders22LocalResponsesProviderV13ConfigurationV12capabilities0A6Models17ModelCapabilitiesVvp` |
| `Configuration.init(...)` | Initializer | `LocalResponsesProvider.swift:45` | `s:14AgentProviders22LocalResponsesProviderV13ConfigurationV7baseURL5model14authentication19maximumOutputTokens12capabilitiesAE10Foundation0H0V_SSAA0cD14AuthenticationVSi0A6Models17ModelCapabilitiesVtcfc` |
| `LocalResponsesProvider.model` | Instance property | `LocalResponsesProvider.swift:60` | `s:14AgentProviders22LocalResponsesProviderV5model0A6Models7ModelIDVvp` |
| `LocalResponsesProvider.descriptor` | Instance property | `LocalResponsesProvider.swift:61` | `s:14AgentProviders22LocalResponsesProviderV10descriptor0A6Models05ModelE10DescriptorVvp` |
| `LocalResponsesProvider.description` | Instance property | `LocalResponsesProvider.swift:68` | `s:14AgentProviders22LocalResponsesProviderV11descriptionSSvp` |
| `LocalResponsesProvider.debugDescription` | Instance property | `LocalResponsesProvider.swift:69` | `s:14AgentProviders22LocalResponsesProviderV16debugDescriptionSSvp` |
| `LocalResponsesProvider.customMirror` | Instance property | `LocalResponsesProvider.swift:70` | `s:14AgentProviders22LocalResponsesProviderV12customMirrors0G0Vvp` |
| `LocalResponsesProvider.init(configuration:transport:)` | Initializer | `LocalResponsesProvider.swift:74` | `s:14AgentProviders22LocalResponsesProviderV13configuration9transportA2C13ConfigurationV_AA0E13HTTPTransport_ptKcfc` |
| `LocalResponsesProvider.stream(request:)` | Instance method | `LocalResponsesProvider.swift:113` | `s:14AgentProviders22LocalResponsesProviderV6stream7requestScsy0A6Models10ModelEventOs5Error_pGAF0I7RequestV_tF` |

ExternalClient constructs the provider through this surface without
`@testable`, package, or internal imports.
