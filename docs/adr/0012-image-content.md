# ADR 0012: Image content in model messages

Status: accepted (2026-10-04); implemented on `claude/image-content`. Proposed
2026-10-01. Audio and video are outside this decision.

## Context

At baseline `74771806ea410f1648eba8d9b5d244f87b001815`, `ModelContent` carried
text, reasoning, JSON and provider continuation, without a typed image payload.
A Host needing screenshots or rendered-frame inspection needs a media path; a
textual description is not native image evaluation.

## Decision

**Content.** `ModelContent.image(ModelImage)` carries Host-supplied bytes. The
initializer recognizes PNG, JPEG, GIF and WebP from the leading bytes (a
declared type must match), refuses empty data, more than
`ModelImage.maximumByteCount` (3.75 MiB, so the base64 form fits the 5 MiB
Anthropic allows for an image's encoded data) and more than 8,000 pixels a side
when the header gives the size, and requires a short text alternative
(`description`, at most 1,024 UTF-8 bytes). Only the header is checked: bytes
damaged after it are accepted and fail at the provider. Identity is the lowercase SHA-256 of
the bytes (`digest`), computed without a crypto dependency in AgentModels.
Pixel size is read from the header when present. Equality is digest, media type
and description. Images belong in user messages and tool results; assistant
content never carries them: a projection that puts one there fails before
dispatch (`invalidProjection`) and adapters refuse it.

The SDK never downloads, resolves paths or URLs, or performs OCR. There is no
Host-resolved reference case: bytes are always present in memory, and the Host
remains responsible for authorizing what it reads before making an image.

**Tools.** `ToolResult(images:)` adds at most
`ModelImage.maximumImagesPerMessage` (8) images after the tool's output in its
result message. More fail the call after the executor ran, like an invalid
output. A settled mutation replay returns its stored output without images.

**Explicit choice per Run.** `AgentModelBinding(imageInput:)` takes an
`AgentImageInputPolicy`, applied to the projected request just before token
estimation and dispatch; the canonical conversation keeps every image:

- `.reject` (default, also for `Agent(model:provider:)`): a request containing
  an image fails before dispatch with
  `AgentLoopError.unsupportedCapabilities(.imageInput)`.
- `.describe`: each image is sent as `ModelImage.textSubstitute`. This is the
  Host's explicit choice for a model that does not see images.
- `.native(maximumImagesPerRequest:maximumImageBytesPerRequest:)` (1...20
  images, default 20, since Anthropic lowers its pixel limit above 20; 1 byte to
  24 MiB, default 20 MiB, so the base64 form stays within Anthropic's 32 MB
  request): images are sent. The adapter must declare
  `ModelCapabilities.imageInput`, or the request fails before dispatch. The
  newest images are sent while they fit both limits; older ones in that request
  are sent as their text substitutes. Such a request's projection plan is marked
  lossy; context reports do not yet count described images.

Support therefore needs both the model (the Host's knowledge, e.g. its catalog)
and the working adapter (`.imageInput`); neither alone sends an image.

**Adapters.** Anthropic sends base64 `image` blocks in user turns and inside
`tool_result` content. OpenAI Responses sends `input_image` data URLs in user
messages and in an array `function_call_output.output`. The local Responses
adapter does so only when configured with `.imageInput`. DeepSeek and Apple
Foundation Models refuse images with `unsupportedCapability`. Requests without
images keep their previous wire shapes.

**Budget.** Request byte limits and the projection source digest encode images
by identity only (`ModelImage.referenceOnlyEncoding`). Token estimates count
them: `ModelImage.estimatedInputTokens` is the larger of the Anthropic
pixel-area rule and the OpenAI high-detail tile rule, and 1,600 when the size is
unknown; `AgentContextTokenEstimationInput.imageInputTokens` sums them for Host
estimators. Estimates are not pricing guarantees.

**Persistence.** A durable store created with `supportsImageContent: true` uses
format schema 10 (which includes schema 9). Records hold only the image's media
type, digest, size and description; the bytes are kept once per digest in the
store's `images/` directory, written durably before the batch that refers to
them. Reading a message loads and verifies the bytes against the digest
(`checksumMismatch` otherwise), so a reopened Session or an unfinished Run's
history gets the image back. Stores of schema 3–9 are never migrated. With
them, a read-only tool's images fail its result with `unsupportedFormat` before
anything is committed (the conversation can go on); a mutation's effect has
already happened, so its settlement is committed with each image as its text
substitute rather than quarantined. Schema-9
readers reject schema 10 before any write (checked by
`Scripts/verify-image-content-compatibility.sh`). Memory journals keep images
in memory. Image files live for the store's lifetime; maintenance does not
collect them.

**Audit.** A result record lists the image digests (`imageDigests`), never the
bytes; regular export includes the digests only.

## Consequences

- Exhaustive switches over `ModelContent` must handle `.image`.
- Hosts opt in per Run; nothing changes for Runs that never meet an image.
- A Host keeping conversations on schema 3–9 stores must describe images
  itself (or create new stores with image support).
- Disk use grows with distinct images per store until the store is deleted.
- Every image in the history is held in memory, and reading the history reads
  and verifies each image file; long image-heavy conversations cost memory and
  I/O in proportion.

## Not decided here

Audio and video, media fetching, image output from models, user-turn image
input through `AgentSession.run(_:)`, and garbage collection of image files.
