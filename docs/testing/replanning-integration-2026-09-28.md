# Bounded replanning dependency integration

The immutable RC4 comparison remains
`3f01599ef3d0923659226025a7d34d4144ed1800`.
Tests-only PR #26 (`5d792457a2b39f712e5f7279d51cb081c1080693`)
merged through GitHub as `45260a247724d5c6487a95fa6e6d9ab22a7a1a01`.
Its normal ExternalClient baseline passed 4/4. Its separate strict probe
exited 1 for both T1/T2 with no post-denial Provider request, preserving the
historical RC4 measurement. Nothing in #26 was changed to make it green.

PR #27 (`0cfd8a20a0061981cb67d6de3f0aee3d6503ade9`) was retargeted to
main after #26 merged. Its remaining diff contained the implementation and
targeted audit fixes, without a duplicate of #26. GitHub's old stacked merge
ref still named `5d79245` as its first parent, so local acceptance used a
clean detached merge candidate with actual parents `45260a2` and `0cfd8a2`:
`257c87ac43a9e52a62c2d5f814c20c3dd150eb75`, tree
`fe5d290ab64c24e5056fd63851f9f3081d659780`. The candidate passed
`ci-macos.sh`, `ci-concurrency-seal.sh`, strict T1/T2 and the original-RC4
reader matrix. PR #27 then merged through GitHub as
`837748f5dade1e18fc86370e4333d3bb95fe9a87` with the same tree.

Final main `837748f` passed a full local macOS gate in a fresh, clean worktree,
the concurrency seal, separate strict probe and the whole-store reader matrix.
The first local worktree's complete gate hung at an existing
`FollowUpProcessTests` `Process.waitUntilExit()` call; that attempt was
terminated and was **not** counted as a pass. The isolated test passed on
retry and the full fresh-worktree gate passed. The main push workflow
`36418419849` checked out head `837748f` and passed hosted macOS, Linux and
Apple jobs. The Git tree for that exact head is
`fe5d290ab64c24e5056fd63851f9f3081d659780`. No tag or Release was
created, and no product Host dependency or user store was switched.

The final contract remains: policy disabled by default; default Journal create
uses schema 3; explicitly capable create uses schema 4; RC4 refuses schema 4
even before its first denial; schema-3 opt-in fails before Provider contact;
no automatic migration, in-place upgrade or downgrade. A new store does not
inherit mutation identities from an old store. The typed denial is neither a
Receipt, Evidence nor authorization. The operation index only queries the
canonical mutation ledger; durable admission remains the effect authority.
Public enum additions affect exhaustive source switches independently of disk
format compatibility. The RC4 release note remains historical and does not
claim this feature.
