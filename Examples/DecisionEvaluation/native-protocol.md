# Native OpenAI Decisions protocol status

Checked public official materials on **2026-10-01 JST** (2026-09-30 UTC).
The Host confirmed there are no additional authorized preview materials.
This is a bounded protocol investigation, not a claim private previews do not
exist. No native adapter, guessed endpoint/model/schema, or invented fixture
is published.

Official sources checked:

- [GPT-6 Luna model documentation](https://developers.openai.com/api/docs/models/gpt-6-luna):
  `gpt-6-luna` is an actual model ID/snapshot for documented Responses,
  Chat Completions and Batch endpoints. Text/image input and Structured Outputs
  are documented. That establishes ordinary model capability, not a native
  Decisions protocol or this account's entitlement.
- [Structured Outputs guide](https://developers.openai.com/api/docs/guides/structured-outputs):
  Responses uses `text.format` with JSON Schema; refusal/incomplete handling
  remains necessary. A schema-generated classification/confidence is not a
  service-native probability distribution.
- [Official Python SDK at 7f203fd](https://github.com/openai/openai-python/tree/7f203fd5cfd96354524cd07498497b2e27184f95/src/openai/resources):
  snapshot commit `7f203fd5cfd96354524cd07498497b2e27184f95`, tree
  `517b66e58276787381511b2b40ccd292252fff34`, commit time
  `2026-09-30T06:36:56Z`. Its complete recursive tree has Responses resources
  and no decision-named resource/type paths. That absence is supporting
  inventory, not proof against an unadvertised interface.
- Official documentation searches for Decisions API, decision endpoint,
  classification/probability and Luna did not establish a native wire schema.

| Capability | Existing Jev SDK | OpenAI native Decisions | Ordinary OpenAI Responses |
| --- | --- | --- | --- |
| Protocol / model | System One; Host model alias, returned model preserved | Not established | Documented endpoint; `gpt-6-luna` is real |
| Noul / Choice / Score | Existing typed results unchanged | Unknown; no conversion or guessed support | JSON Schema output alone does not establish these native types |
| Probability / confidence | Existing reported values, not normalized | Meaning absent | Generated confidence must not be called native probability |
| Text evaluation | Public SDK consumer + loopback protocol tests | Unsupported before dispatch | Separate adapter/label would be required; not delivered here |
| Image input / counts / MIME | This evaluation is text-only | Unknown; no upload, OCR or URL fetching | Ordinary image capability documented; not native confirmation |
| Usage / errors / eligibility | Existing mapping tested offline; live NOT RUN | Unknown; live NOT RUN | Ordinary docs do not establish native permissions |

Required material before native implementation:

1. Official endpoint, protocol/version and actual permitted API model IDs.
2. Exact request/response schema, question/answer types, IDs and candidate
   case/membership rules, counts and supported combinations.
3. Native media representation (bytes/references), MIME/size/count limits and
   authorized fetching/upload behavior.
4. Boolean vs probability, selection vs full distribution, confidence origin,
   expected vs discrete score, optional fields and numeric/sum guarantees.
5. Usage, HTTP/error/refusal/truncation/cancellation semantics and response limit.
6. Authentication, preview entitlement, account/region/deployment eligibility
   and pricing sufficient for a separately authorized bounded live batch.

Common evaluation/Jev is implemented without changing Decision public
Codable/API or making Core depend on decision services. Native integration is
**BLOCKED_PROTOCOL / NOT IMPLEMENTED**. Live service and model-quality results
are **NOT RUN**. Ordinary Responses + Structured Outputs remains an optional,
separately named `openai-responses-structured` comparison; it is not a fallback
and is not implemented or timed as native Decisions in this delivery.
