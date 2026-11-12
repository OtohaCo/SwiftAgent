import Foundation
#if os(Windows)
import WinSDK
#elseif canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// The writer owns this non-inheritable handle until close, including during opening/recovery.
/// Closing or process death releases the OS lock; the file must never be deleted by an owner.
final class JournalWriterLock {
    struct Contended: Error {}
    struct Unavailable: Error { let cause: any Error }
    #if os(Windows)
    private var handle: HANDLE?
    #else
    private var descriptor: Int32?
    #endif

    init(file: URL, retry: (() throws -> Void)? = nil, contended: () -> Void = {}) throws {
        #if os(Windows)
        let opened = file.path.withCString(encodedAs: UTF16.self) {
            CreateFileW($0, DWORD(GENERIC_READ) | DWORD(GENERIC_WRITE), DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE),
                        nil, DWORD(OPEN_ALWAYS), DWORD(FILE_FLAG_OPEN_REPARSE_POINT), nil)
        }
        guard let opened, opened != INVALID_HANDLE_VALUE else { throw Self.windowsError() }
        do {
            var info = BY_HANDLE_FILE_INFORMATION()
            guard GetFileInformationByHandle(opened, &info),
                  info.dwFileAttributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_DIRECTORY) == 0 else {
                throw Unavailable(cause: CocoaError(.fileReadNoPermission))
            }
            var overlap = OVERLAPPED()
            while !LockFileEx(opened, DWORD(LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY), 0, 1, 0, &overlap) {
                let code = GetLastError()
                guard code == ERROR_LOCK_VIOLATION else { throw Self.windowsError(code) }
                contended()
                guard let retry else { throw Contended() }
                try retry()
            }
            handle = opened
        } catch { CloseHandle(opened); throw error }
        #else
        let opened = open(file.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard opened >= 0 else { throw Unavailable(cause: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)) }
        do {
            while flock(opened, LOCK_EX | LOCK_NB) != 0 {
                let code = errno
                if code == EINTR { continue }
                guard code == EWOULDBLOCK || code == EAGAIN else { throw Unavailable(cause: POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)) }
                contended()
                guard let retry else { throw Contended() }
                try retry()
            }
            descriptor = opened
        } catch { _ = systemClose(opened); throw error }
        #endif
    }

    func close() throws {
        #if os(Windows)
        guard let handle else { return }
        guard CloseHandle(handle) else { throw Self.windowsError() }
        self.handle = nil
        #else
        guard let descriptor else { return }
        self.descriptor = nil
        guard systemClose(descriptor) == 0 else { throw Unavailable(cause: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)) }
        #endif
    }

    deinit { try? close() }

    /// How long fail-fast ownership keeps retrying a contended lock before it reports
    /// `storeInUse`. A child process the host is starting shares the close-on-exec lock
    /// descriptor until it execs, so an open right after `close()` can see the lock held
    /// for that moment. A real owner still holds it after this bound.
    static let spawnWindowGrace: Duration = .milliseconds(250)

    static func spawnWindowRetry() -> @Sendable () throws -> Void {
        let end = ContinuousClock.now.advanced(by: spawnWindowGrace)
        return {
            guard ContinuousClock.now < end else { throw Contended() }
            Thread.sleep(forTimeInterval: 0.001)
        }
    }

    #if os(Windows)
    private static func windowsError(_ code: DWORD = GetLastError()) -> Unavailable { Unavailable(cause: NSError(domain: "Win32", code: Int(code))) }
    #endif
}

#if !os(Windows)
private func systemClose(_ descriptor: Int32) -> Int32 { close(descriptor) }
#endif
