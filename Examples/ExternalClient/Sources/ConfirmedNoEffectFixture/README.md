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

The store is disposable, explicitly schema 6, and deleted after owned work
actually drains/closes. This is not a production directory or migration example.
[Contract and Host sample](../../../../docs/guides/swift-agent-confirmed-no-effect.md).
