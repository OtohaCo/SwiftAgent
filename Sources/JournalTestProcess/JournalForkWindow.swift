import AgentCore
import Foundation
import JournalProcessPrimitives
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// Real Journal + fork/exec integration. All allocations and argv are prepared
// before fork; the child uses only raw close/read/execv/_exit calls, never SDK or
// Foundation after fork. The outer test launches this helper using Process.
func holdForkWindow(journal: AgentJournal) async throws {
    var gate: [Int32] = [0, 0], execWitness: [Int32] = [0, 0]
    guard pipe(&gate) == 0, pipe(&execWitness) == 0 else { throw POSIXError(.EIO) }
    defer { gate.forEach { _ = close($0) }; execWitness.forEach { _ = close($0) } }
    guard fcntl(execWitness[1], F_SETFD, FD_CLOEXEC) == 0 else { throw POSIXError(.EIO) }
    let pid = swiftagent_test_fork_exec(gate[0], gate[1], execWitness[0], execWitness[1])
    guard pid > 0 else { throw POSIXError(.EIO) }
    defer {
        _ = kill(pid, SIGKILL)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
    }
    _ = close(gate[0]); gate[0] = -1
    _ = close(execWitness[1]); execWitness[1] = -1
    try await journal.close()
    FileHandle.standardOutput.write(Data("WINDOW \(pid)\n".utf8))
    guard try FileHandle.standardInput.read(upToCount: 1)?.count == 1 else { throw POSIXError(.EIO) }
    var release: UInt8 = 1
    guard write(gate[1], &release, 1) == 1 else { throw POSIXError(.EIO) }
    var byte: UInt8 = 0
    guard read(execWitness[0], &byte, 1) == 0 else { throw POSIXError(.EIO) }
    var status: Int32 = 0
    guard waitpid(pid, &status, WNOHANG) == 0 else { throw POSIXError(.EIO) }
    FileHandle.standardOutput.write(Data("EXECUTED\n".utf8))
    _ = try FileHandle.standardInput.read(upToCount: 1) // Host controls actual child lifetime.
}
