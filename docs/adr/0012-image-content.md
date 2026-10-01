# ADR 0012: Image content in model messages

Status: proposed (draft, 2026-10-01); deferred until a Host needs the model to
see images from a user or a tool

## Context

`ModelContent` has `text`, `reasoning`, `json` and `providerContinuation`.
Nothing can carry an image to the model: not a user attachment and not a tool
result. MCP tools return image content blocks (screenshots, thumbnails, rendered
frames), and review tasks such as checking a rendered video frame need vision.
Hosts can only describe images in text today.

## Proposal

- Add an image case to `ModelContent`: media type, data or a Host-resolved
  reference, and optional alternative text. It is allowed in user and tool
  messages, not in system or developer messages.
- Providers declare image input support per model in the catalog. A request
  that carries images to a model without support fails before Provider contact
  with a typed error; the Host decides whether to project a text fallback.
  SwiftAgent never drops an image silently.
- The journal stores images by content digest with a size limit, not inline in
  every checkpoint, behind schema negotiation like other persisted additions.
  Audit export keeps digests only.
- Token estimation gains provider-specific image cost estimates.

## Open questions

- Inline data versus digest references resolved through a Host store.
- Size and count limits per message and per Run.
- Whether audio follows the same pattern later. This ADR does not propose it.
