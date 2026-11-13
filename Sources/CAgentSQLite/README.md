# CAgentSQLite

SQLite compiled from its amalgamation for platforms without a system SQLite module: Linux (including the Swift
Static Linux SDK, which has no `libsqlite3`) and Windows. `AgentJournalSQLiteStore` uses it there; on Apple
platforms it imports the system's `SQLite3` and this target compiles nothing.

An application that also needs SQLite on Linux or Windows should depend on the `CAgentSQLite` product rather than
compile a second copy: two copies of the amalgamation in one executable would define every `sqlite3_*` symbol twice.
Applications that only use `AgentJournalFileStore` never build or link this target.

| | |
| --- | --- |
| Version | 3.53.4 (source id `2026-07-24 19:02:57 bf7c7f30031888f4e796e429ab3978879485813aaca6f641c7b33e4e09459bcc`) |
| Source | <https://sqlite.org/2026/sqlite-amalgamation-3530400.zip> |
| SHA3-256 of the zip (as on sqlite.org/download.html) | `628a44cfe82c66aed1ccbbe85a562d2e33ebe64b3288981ed76285612227934e` |
| SHA-256 of the zip | `1e71ddf93849c6a6ecf58b827c0692073d2dd7ee40196158068f7b29f422e87d` |
| SHA-256 of `sqlite/sqlite3.c` | `b1dd5d74ec7f29055a6684fa06fb3c2f6821c87dd38f9a458dfd2e8a1db28189` |
| SHA-256 of `include/sqlite3.h` | `919e7f2e8ed1d8f56ac17b412b8971c76aa5d1a879752cc6058f75e7d5910e1d` |

`sqlite/sqlite3.c` and `include/sqlite3.h` are the files from the zip, unchanged. The compile settings are in
`Package.swift` (target `CAgentSQLite`): serialized threading (`SQLITE_THREADSAFE=1`), write-ahead logging left on
(the default), FTS5 on (`SQLITE_ENABLE_FTS5`, as Apple's system SQLite has it), no loadable extensions, and `usleep`
for the busy wait so a locked database is retried in milliseconds rather than whole seconds.

To update: download the new amalgamation zip, check its SHA3-256 against sqlite.org's download page, replace the two
files, and update the table above.

## License

SQLite is in the public domain. The authors' notice, as it stands at the top of `sqlite3.c`:

> The author disclaims copyright to this source code. In place of a legal notice, here is a blessing:
>
> May you do good and not evil.
> May you find forgiveness for yourself and forgive others.
> May you share freely, never taking more than you give.

See <https://sqlite.org/copyright.html>.
