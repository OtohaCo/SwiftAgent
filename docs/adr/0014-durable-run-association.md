# ADR 0014: Durable Run admission and logical termination

Status: Accepted design for Issue #75; implementation is isolated above #74.

`run(..., correlation:)` adds a bounded UTF-8 Host key and supplied payload
identity. The actual store + Session + exact key is the scope. The SDK binds
exact formal text and operation ID independently of the supplied digest. The
Host digest declares stable configuration identity; it neither freezes Host
code nor restores runtime handles/permissions. Rebuilt bindings are allowed.

A startup transaction publishes the Run association, formal user message and
checkpoint together. A duplicate committed payload throws alreadyAdmitted
with its original record; a changed payload conflicts. During uncommitted
startup an overlapping submission returns admissionInProgress, never a
fictional committed record. Existing Session/Journal ownership prevents two
workers. An unknown commit keeps the failed owned Run and poisons writes.

On a store explicitly created with Run-record support, all Runs (including
follow-ups without a key) acquire an indexed admission. Actual loop ownership
publishes logical terminal after in-flight checkpoint writes and retained
steering are resolved, before exposing a terminal event/wait result. Terminal
and the then-final canonical checkpoint share one transaction. Terminal write
failure replaces the control outcome with the visible persistence error;
poison/unknown storage never receives a blind second append. No wait() caller
owns publication. Drain/leases still wait for physical executors. Trusted late
settlement may append separately without rewriting the logical terminal.

Terminals distinguish completed, refused, incomplete, cancelled and failed.
Only closed, bounded enums are stored: no provider text, exception description,
credentials or arbitrary failure strings. Limits/deadline map to incomplete.

Indexed read-only queries by key/Run ID return notAdmitted, admitted or terminal;
store errors remain errors. They do not dispatch, recover or release barriers.
Old formats have no complete admission/terminal index and explicitly reject
this capability, including for old Runs. Missing witnessed indexes are corruption.

Opt-in creation uses the next format boundary (schema 9), includes #74/schema-8
capabilities, and creates witnessed admission/correlation/terminal indexes.
Old binaries reject before ownership/writes. No migration or second ledger.
Maintenance retains bounded admission/terminal frames and indexes for the whole
store lifetime, without retaining a full history array per Run. There is no
key expiry/deletion API. Future body deletion must retain identity tombstones
or fail lookup with unsupported capability; absence must never mean unexecuted.
