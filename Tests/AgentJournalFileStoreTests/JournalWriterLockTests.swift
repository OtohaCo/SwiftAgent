import Foundation
import Testing
@testable import AgentJournalFileStore

struct JournalWriterLockTests {
    @Test func contentionAndRelease() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(".writer.lock")
        let first = try JournalWriterLock(file: file)
        #expect(throws: (any Error).self) { try JournalWriterLock(file: file) }
        try first.close()
        let second = try JournalWriterLock(file: file)
        try second.close()
        try second.close()
    }
}
