#if os(Windows)
import Foundation
import WinSDK
import ucrt

/// Same-volume publication follows a flush of the complete file. Windows has no directory fsync;
/// MOVEFILE_WRITE_THROUGH is the publication barrier, not a simulated successful POSIX fsync.
enum JournalWindowsIO {
    /// Normalize ordinary DOS dot/root semantics before opting into the extended
    /// namespace, which itself disables Win32 path normalization. Already-extended
    /// paths keep their literal namespace semantics. Never pass embedded NUL to C.
    static func nativePath(_ path: String) throws -> String {
        guard !path.isEmpty, !path.utf16.contains(0) else {
            throw NSError(domain: "Win32", code: Int(ERROR_INVALID_NAME))
        }
        if path.hasPrefix("\\\\?\\") {
            guard path.utf16.count < 32_767 else {
                throw NSError(domain: "Win32", code: Int(ERROR_FILENAME_EXCED_RANGE))
            }
            return path
        }
        let ordinary = path.replacingOccurrences(of: "/", with: "\\")
        let units = Array(ordinary.utf16)
        let drive = units.count >= 3 && ((65...90).contains(units[0]) || (97...122).contains(units[0]))
            && units[1] == 58 && units[2] == 92
        let unc = ordinary.hasPrefix("\\\\") && !ordinary.hasPrefix("\\\\.\\") && !ordinary.hasPrefix("\\\\?\\")
        guard drive || unc else { throw NSError(domain: "Win32", code: Int(ERROR_INVALID_NAME)) }
        guard units.count < 32_767 else {
            throw NSError(domain: "Win32", code: Int(ERROR_FILENAME_EXCED_RANGE))
        }
        // Absolute input avoids process-global current-directory races. One bounded
        // allocation also avoids a size-query/use race and handles paths > MAX_PATH.
        var buffer = [WCHAR](repeating: 0, count: 32_768)
        let count = ordinary.withCString(encodedAs: UTF16.self) {
            GetFullPathNameW($0, DWORD(buffer.count), &buffer, nil)
        }
        guard count != 0 else { throw failure() }
        guard count < DWORD(buffer.count) else {
            throw NSError(domain: "Win32", code: Int(ERROR_FILENAME_EXCED_RANGE))
        }
        let absolute = String(decoding: buffer.prefix(Int(count)), as: UTF16.self)
        let result: String
        if unc {
            let components = absolute.dropFirst(2).split(separator: "\\", omittingEmptySubsequences: false)
            guard components.count >= 2, !components[0].isEmpty, !components[1].isEmpty else {
                throw NSError(domain: "Win32", code: Int(ERROR_INVALID_NAME))
            }
            result = "\\\\?\\UNC\\" + absolute.dropFirst(2)
        } else {
            result = "\\\\?\\" + absolute
        }
        guard result.utf16.count < 32_767 else {
            throw NSError(domain: "Win32", code: Int(ERROR_FILENAME_EXCED_RANGE))
        }
        return result
    }

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
        let opened = try nativePath(url.path).withCString(encodedAs: UTF16.self) {
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
        let fromPath = try nativePath(source.path)
        let toPath = try nativePath(destination.path)
        let published = fromPath.withCString(encodedAs: UTF16.self) { from in
            toPath.withCString(encodedAs: UTF16.self) {
                MoveFileExW(from, $0, DWORD(MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
            }
        }
        guard published else { throw failure() }
    }

    static func validateDirectory(_ url: URL, follow: Bool = false) throws {
        let opened = try nativePath(url.path).withCString(encodedAs: UTF16.self) {
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
