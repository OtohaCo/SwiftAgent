# Issue #112 implementation and release plan

Approved design: ../specs/2026-10-13-gemini-native-provider-design.md.
The writing-plans skill is unavailable in this session; use the repository's existing plan format and CONTRIBUTING TDD requirements.

1. Preserve a compiled missing-file-contract RED at the current source. Add validated public ModelFileReference, file capability, AgentRunInput, file policy and signature-preserving binding overloads. Thread immutable attachments through preflight/admission; bind attachments in correlation fingerprints while keeping text-only bytes unchanged.
2. Add opt-in schema 13 and explicit file persistence guards. Preserve all old create/open signatures, defaults and the existing 11→12 upgrade. Add public file/reopen/correlation tests and a real schema-12 older-reader rejection gate to Linux/macOS scripts. Run affected Core/Models/compatibility checks.
3. Add native Gemini credentials/configuration, canonical request encoder, ordered opaque continuation and bounded stream/nonstream decoder. Verify parallel/sequential tools, exact signed parts, sparse usage, refusals and local request restrictions through real Swift HTTP fixtures; cancellation/deadline/drain must retain late credential callbacks.
4. Add provider-specific implicit/explicit prompt caching with a frozen request prefix/resource witness, Host-invoked create/delete client and scoped models.list catalog. Verify exact match/mismatch, expiry, error classification, credential rotation, body limits and no automatic Run replay.
5. Add public-only ExternalClient fixtures for attachment admission, native multi-step tools/thinking, canonical/Run-record preservation, cancellation/drain, reopen and explicit cache preparation. Document supported and locally refused paths; no live/Host qualification claims.
6. Obtain three independent reviews of the actual final diff and results; fix or provide executable counterevidence for all blocking findings. Run final full applicable local/hosted gates, merge via PR and verify actual main/source metadata.
7. Reseal complete RC5→RC6 release materials including #110/#112 and preserved historical failures. Repeat anonymous revision consumer, annotated immutable tag, matching tag CI, exact-version consumer and authorized GitHub Pre-release. OtohaAI remains a separate task.
