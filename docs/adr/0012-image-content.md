# ADR 0012: Image content in model messages

Status: proposed (2026-10-01); deferred; not implemented

Merging the document does not add image support to RC6 or select a final media
API. Audio is outside this proposal. Implementation and acceptance are separate.

## Context

At baseline `74771806ea410f1648eba8d9b5d244f87b001815`, `ModelContent` carries
text, reasoning, JSON and provider continuation, without a typed image payload.
A Host needing screenshots or rendered-frame inspection needs a separately
designed media path; a textual description is not native image evaluation.

## Proposed direction and reference boundary

An image case could carry MIME type, Host-provided data or a Host-resolved
reference, immutable content identity and optional alternative text. Exact
representation and permissible message roles remain implementation questions.

A Host-resolved reference is **not** authorization to read arbitrary paths or
URLs. The Host owns authorized resolution and immutable content identity.
SDK/Provider adapters enforce necessary MIME, size, count and capability checks.
Do not implicitly download, transmit images or perform OCR. A digest supports
association/integrity; it does not prove retrievability or access permission.

Support must be confirmed by both the actual model's capability and the working
Provider adapter, not merely a catalog flag. Unsupported content or insufficient
budget must fail explicitly before the relevant dispatch. A textual substitute
requires an explicit Host choice; never silently discard an image.

Image persistence, material lifetime, authorized reference resolution, recovery,
maintenance and any disk-format boundary must be independently verified in the
implementation. Content-addressed storage may avoid repeated checkpoint copies,
but this proposal neither delivers that store nor fixes its final API. Restricted
image data is not automatically part of audit export; export policy remains
explicit and a digest-only view is not a recoverable material backup.

Token/resource estimates and costs are Provider/model-specific. Unknown values
are not zero; an image token estimate is not a universal exact pricing guarantee.
Validation of actual accounting belongs to the independent implementation stage.

## Open questions

- Inline bytes versus immutable references and their authorized resolver.
- MIME/size/count limits per message and Run; supported roles and adapters.
- Persistence, lifecycle, recovery, budget estimation and compatibility.

This document does not propose audio, implement media fetching or claim any
image runtime capability in release notes.
