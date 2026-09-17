import AgentModels
import Foundation

struct ProviderSSEEvent: Equatable, Sendable {
    let name: String?
    let data: String
}

struct ProviderSSEDecoder {
    private var line: [UInt8] = []
    private var dataLines: [String] = []
    private var name: String?
    private var skipLF = false
    private let maximumEventBytes: Int
    private var eventBytes = 0

    init(maximumEventBytes: Int = 1_048_576) throws {
        guard maximumEventBytes > 0 else {
            throw ModelProviderError(kind: .invalidRequest, message: "The event size limit must be positive.")
        }
        self.maximumEventBytes = maximumEventBytes
    }

    mutating func consume(_ bytes: Data) throws -> [ProviderSSEEvent] {
        var events: [ProviderSSEEvent] = []
        for byte in bytes {
            if skipLF {
                skipLF = false
                if byte == 10 { continue }
            }
            guard eventBytes < maximumEventBytes else {
                throw ModelProviderError(kind: .invalidResponse, message: "The event stream frame exceeded its size limit.")
            }
            eventBytes += 1
            if byte == 10 || byte == 13 {
                skipLF = byte == 13
                guard let text = String(bytes: line, encoding: .utf8) else {
                    throw ModelProviderError(kind: .invalidResponse, message: "Invalid UTF-8 in event stream.")
                }
                line.removeAll(keepingCapacity: true)
                if text.isEmpty {
                    if !dataLines.isEmpty { events.append(.init(name: name, data: dataLines.joined(separator: "\n"))) }
                    dataLines.removeAll(keepingCapacity: true)
                    name = nil
                    eventBytes = 0
                } else if !text.hasPrefix(":") {
                    let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                    var value = parts.count == 2 ? String(parts[1]) : ""
                    if value.hasPrefix(" ") { value.removeFirst() }
                    switch parts[0] {
                    case "event": name = value
                    case "data": dataLines.append(value)
                    default: break
                    }
                }
            } else {
                line.append(byte)
            }
        }
        return events
    }

    func finish() throws {
        guard line.isEmpty, dataLines.isEmpty, name == nil else {
            throw ModelProviderError(kind: .invalidResponse, message: "The event stream ended inside a frame.")
        }
    }
}
