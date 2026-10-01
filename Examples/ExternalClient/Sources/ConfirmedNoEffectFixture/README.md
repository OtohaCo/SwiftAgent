# ConfirmedNoEffectFixture

No credentials or network. This package-outside-SDK consumer uses public
Agent/Session/Run, a synthetic provider and a controlled temporary file. It
never directly executes a tool or creates internal Journal facts.

From the repository root:

```sh
swift run --package-path Examples/ExternalClient ConfirmedNoEffectFixture corrected
swift run --package-path Examples/ExternalClient ConfirmedNoEffectFixture default
swift run --package-path Examples/ExternalClient ConfirmedNoEffectFixture unknown
```

`corrected`: A enters the executor, rejects the entire operation before any
write and explicitly confirms no outstanding work. One commit publishes proof,
abort, paired model error, checkpoint and executor audit reference. Only then
B is proposed under the same Run/operation and goes through fresh enterprise
and tool authorization/admission. B writes once and returns a successful Receipt.
The fixture closes/reopens and compares committed proof/history.

Independent counts: provider requests 3; invocation identities 2; enterprise
and tool authorizations 2 each; intents 2 (per-call ledger query); authorization
applications 2; final admissions 2; executor entries 2; no-effect confirmations 1;
file effects 1; abort references 1; settlements 1; successful Receipts 1.
A's executor entry is not zero: its business effect is zero.

`default`: no opt-in; confirmation factory is unavailable and the ordinary
closed mutation failure leaves one intent for reconciliation, no model feedback
or second turn. `unknown`: opted-in policy but ordinary uncertain failure, also
requiring reconciliation. Both have provider/executor 1 and file effects 0.
Closing/reopening does not execute any operation or mint a permission.

The store is disposable, explicitly schema 7, and deleted after owned work
actually drains/closes. This is not a production directory or migration example.
[Contract and Host sample](../../../../docs/guides/swift-agent-confirmed-no-effect.md).


Large-body public SDK fixtures (disposable store and real temporary file):

```sh
swift run --package-path Examples/ExternalClient ConfirmedNoEffectFixture large 143000 default-id
swift run --package-path Examples/ExternalClient ConfirmedNoEffectFixture large 250000 stable-id
swift run --package-path Examples/ExternalClient ConfirmedNoEffectFixture large 256001 stable-id
swift run --package-path Examples/ExternalClient ConfirmedNoEffectFixture large-audit 250000 stable-id
```

`large` uses legacy authorization, with fresh tool authorization for A and B.
It verifies the unchanged stable key contains all normalized parameters and
validates the original executor Receipt. The next provider request checks
committed proof, zero pending, paired canonical history and zero file effects.
It records independent provider/executor/intent/abort/effect/Receipt counts,
proof size and original key size, then runs actual maintenance and close/reopen.
Above the fixture Host's 256,000-byte limit, A returns a whole-operation rejected
confirmation and B supplies smaller content. Other large A calls conflict
before any write; B writes once.

`large-audit` deliberately preserves requiredAudit's 64 KiB capture rejection.
It records `proposalTooLarge`, provider 1, authorization/executor/intent/effect 0,
proof 0 and pending 0. It does not claim enterprise large-body support. The
original `corrected` mode verifies the normal audited no-effect path within
that limit. Parameters and retained intent remain bounded; this fixture is not
an arbitrary-size API or a pending-recovery shortcut.
