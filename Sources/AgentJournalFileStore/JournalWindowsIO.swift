#if os(Windows)
import Foundation
import WinSDK
import ucrt

/// Same-volume publication follows a flush of the complete file. Windows has no directory fsync;
/// MOVEFILE_WRITE_THROUGH is the publication barrier, not a simulated successful POSIX fsync.
enum JournalWindowsIO {
    static func open(_ url: URL, access: DWORD = DWORD(GENERIC_READ), creation: DWORD = DWORD(OPEN_EXISTING)) throws -> FileHandle {
        // Match writeNew's POSIX 0600 before writing, even under a shared project directory.
        var security: PSECURITY_DESCRIPTOR?
        if creation == DWORD(CREATE_NEW) {
            let converted = "D:P(A;;FA;;;OW)(A;;FA;;;SY)".withCString(encodedAs: UTF16.self) {
                ConvertStringSecurityDescriptorToSecurityDescriptorW($0, DWORD(SDDL_REVISION_1), &security, nil)
            }
            guard converted else { throw failure() }
        }
        defer { if let security { LocalFree(security) } }
        var attributes = SECURITY_ATTRIBUTES()
        attributes.nLength = DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size)
        attributes.lpSecurityDescriptor = security
        attributes.bInheritHandle = false
        let opened = url.path.withCString(encodedAs: UTF16.self) {
            CreateFileW($0, access, DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE), &attributes, creation,
                        DWORD(FILE_FLAG_OPEN_REPARSE_POINT), nil)
        }
        guard let opened, opened != INVALID_HANDLE_VALUE else { throw failure() }
        var info = BY_HANDLE_FILE_INFORMATION()
        guard GetFileInformationByHandle(opened, &info),
              info.dwFileAttributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_DIRECTORY) == 0 else {
            CloseHandle(opened)
            throw CocoaError(.fileReadNoPermission)
        }
        let mode = access & DWORD(GENERIC_WRITE) == 0 ? _O_RDONLY : _O_RDWR
        let descriptor = _open_osfhandle(Int(bitPattern: opened), mode | _O_BINARY)
        guard descriptor >= 0 else { CloseHandle(opened); throw failure() }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    static func publish(_ source: URL, at destination: URL) throws {
        let published = source.path.withCString(encodedAs: UTF16.self) { from in
            destination.path.withCString(encodedAs: UTF16.self) {
                MoveFileExW(from, $0, DWORD(MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
            }
        }
        guard published else { throw failure() }
    }

    static func validateDirectory(_ url: URL, follow: Bool = false) throws {
        let opened = url.path.withCString(encodedAs: UTF16.self) {
            CreateFileW($0, DWORD(FILE_READ_ATTRIBUTES), DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE),
                        nil, DWORD(OPEN_EXISTING), DWORD(FILE_FLAG_BACKUP_SEMANTICS) | (follow ? 0 : DWORD(FILE_FLAG_OPEN_REPARSE_POINT)), nil)
        }
        guard let opened, opened != INVALID_HANDLE_VALUE else { throw failure() }
        defer { CloseHandle(opened) }
        var info = BY_HANDLE_FILE_INFORMATION()
        guard GetFileInformationByHandle(opened, &info), info.dwFileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0,
              follow || info.dwFileAttributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0 else { throw CocoaError(.fileReadNoPermission) }
    }

    private static func failure() -> NSError { NSError(domain: "Win32", code: Int(GetLastError())) }
}
#endif
