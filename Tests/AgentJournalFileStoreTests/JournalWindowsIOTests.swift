#if os(Windows)
import Foundation
import Testing
import WinSDK
import struct Foundation.UUID
@testable import AgentJournalFileStore

struct JournalWindowsIOTests {
    @Test func newlyCreatedAndPublishedFilesDoNotInheritSharedReadAccess() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func powershell(_ script: String) throws {
            let child = Process()
            let system = ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows"
            child.executableURL = URL(fileURLWithPath: system + "\\System32\\WindowsPowerShell\\v1.0\\powershell.exe")
            child.arguments = ["-NoProfile", "-NonInteractive", "-Command", "$ErrorActionPreference='Stop'; " + script]
            try child.run()
            let deadline = Date().addingTimeInterval(30)
            while child.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if child.isRunning { child.terminate() }
            child.waitUntilExit()
            try #require(child.terminationStatus == 0)
        }
        func quoted(_ url: URL) -> String { "'" + url.path.replacingOccurrences(of: "'", with: "''") + "'" }
        try powershell("$a=Get-Acl \(quoted(root)); $r=[Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-5-32-545'),'Read','ContainerInherit,ObjectInherit','None','Allow'); $a.AddAccessRule($r); Set-Acl \(quoted(root)) $a")
        for name in ["segment", "blob", "publication.tmp"] {
            let file = root.appendingPathComponent(name)
            let handle = try JournalWindowsIO.open(file, access: DWORD(GENERIC_READ | GENERIC_WRITE), creation: DWORD(CREATE_NEW))
            try handle.write(contentsOf: Data("private".utf8))
            try handle.synchronize()
            try handle.close()
            let published = root.appendingPathComponent(name + ".published")
            for url in [file, published] {
                if url == published { try JournalWindowsIO.publish(file, at: published) }
                try powershell("$a=Get-Acl \(quoted(url)); if (!$a.AreAccessRulesProtected) { throw 'Unprotected ACL' }; $r=$a.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]); if ($r.Count -ne 2) { throw 'Unexpected ACL' }; foreach($e in $r) { if ($e.IsInherited -or $e.IdentityReference.Value -notin @('S-1-3-4','S-1-5-18')) { throw 'Shared access' } }")
            }
        }
    }

    @Test func publicationReplacesOnlyWithACompleteFlushedFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let current = root.appendingPathComponent("CURRENT")
        let temporary = root.appendingPathComponent("next.tmp")
        try Data("old".utf8).write(to: current)
        let file = try JournalWindowsIO.open(temporary, access: DWORD(GENERIC_READ | GENERIC_WRITE), creation: DWORD(CREATE_NEW))
        try file.write(contentsOf: Data("complete new generation".utf8))
        try file.synchronize()
        try file.close()
        #expect(try Data(contentsOf: current) == Data("old".utf8))
        try JournalWindowsIO.publish(temporary, at: current)
        #expect(try Data(contentsOf: current) == Data("complete new generation".utf8))
        #expect(!FileManager.default.fileExists(atPath: temporary.path))
        #expect(throws: (any Error).self) { try JournalWindowsIO.publish(temporary, at: current) }
        #expect(try Data(contentsOf: current) == Data("complete new generation".utf8))
    }
}
#endif
