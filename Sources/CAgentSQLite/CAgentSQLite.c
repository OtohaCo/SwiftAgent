// SQLite built from its source where the system has no SQLite library to link: the Swift Static Linux SDK (musl),
// Linux systems without libsqlite3, and Windows. Apple platforms link the system's SQLite (the `SQLite3` module)
// and compile nothing here. The compile settings are in Package.swift; the version and origin are in README.md.
#if !defined(__APPLE__)
#include "sqlite/sqlite3.c"
#endif
