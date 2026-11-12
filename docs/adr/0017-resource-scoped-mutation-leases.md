# ADR 0017: Mutations wait only for overlapping resources

Status: implemented on branch `otoha/review-1110-core2` (2026-11-10); unreleased

## Context

`ToolResourceCoordinator` made any two mutations on one `ToolScheduler` conflict,
whatever resources they declared. Two Sessions writing different files, or working
in different projects, waited for each other, and a long command in one Session held
every other Session's change. Hosts that needed concurrency gave some Sessions their
own scheduler, which also drops the isolation the shared scheduler is documented to
give for the resources they do share.

## Decision

A mutation takes an exclusive lease on its declared resources, exactly as an
exclusive read-only call does. Two leases conflict when at least one is exclusive
and their resources overlap; `.global` overlaps every resource. Shared leases never
conflict with each other. Waiting order is unchanged: a waiter never overtakes an
older conflicting waiter, disjoint work may pass it. Lease-wait limits and
cancellation (ADR 0016) are unchanged.

`resourceRequirements(for:)` keeps its default of `[.global]`, so a tool that
declares nothing still waits for every other call. Validation (no empty, duplicate
or blank names) is unchanged.

## Considered and rejected

- Requiring a mutation's receipt targets to be among its declared resources. Hosts
  legitimately lock a coarse name (a project folder) and prove a finer target (one
  file, one process); the check would reject them without making them safer.
- Folding case or Unicode spelling of resource names in the SDK. Names are host
  identities compared byte-exactly everywhere (Evidence, capability bindings,
  journals); a host whose identities alias must choose names that do not.

## Consequences

The resource names are now the whole cross-Session contract for mutations. A tool
that names less than it touches can overlap another Session's change; before, the
blanket mutation rule hid that for mutation–mutation pairs (not for reads).
WorkspaceAgent's file leases are the exact relative path, so aliasing spellings on a
case-insensitive volume are different leases (see the Workspace host guide).
