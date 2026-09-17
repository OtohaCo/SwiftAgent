import Foundation
import Testing
@testable import AgentProviders

struct ProviderSSEDecoderTests {
    @Test func eventSizeLimitAppliesBeforeAnUnterminatedFrameCanGrow() throws {
        var decoder = try ProviderSSEDecoder(maximumEventBytes: 64)
        #expect(try decoder.consume(Data(repeating: 120, count: 64)).isEmpty)
        #expect(throws: (any Error).self) { try decoder.consume(Data([120])) }
        #expect(throws: (any Error).self) { try ProviderSSEDecoder(maximumEventBytes: 0) }
    }

    @Test func bareCRAndLFDelimitersIgnoreCommentsAndKeepIndependentEvents() throws {
        var decoder = try ProviderSSEDecoder()
        let events = try decoder.consume(Data(": heartbeat\revent: first\rdata: one\r\rid: ignored\nretry: 1000\ndata: two\n\n".utf8))
        #expect(events == [.init(name: "first", data: "one"), .init(name: nil, data: "two")])
        try decoder.finish()
    }

    @Test func malformedUTF8AndTruncatedFramesCannotFinishCleanly() throws {
        var invalid = try ProviderSSEDecoder()
        #expect(throws: (any Error).self) { try invalid.consume(Data([0xff, 10])) }
        for wire in ["data: {}", "data: {}\n", "event: message_stop\ndata: {}\n"] {
            var decoder = try ProviderSSEDecoder()
            _ = try decoder.consume(Data(wire.utf8))
            #expect(throws: (any Error).self) { try decoder.finish() }
        }
    }

    @Test func fragmentedUTF8AndMultilineCRLFProduceOneUnchangedPayload() throws {
        var decoder = try ProviderSSEDecoder()
        let wire = "event: message_start\r\ndata: {\"type\":\r\ndata: \"message_start\",\"text\":\"cafe\u{301}\"}\r\n\r\n"
        var events: [ProviderSSEEvent] = []
        for byte in wire.utf8 { events += try decoder.consume(Data([byte])) }
        try decoder.finish()
        #expect(events.count == 1)
        #expect(events.first?.name == "message_start")
        #expect(events.first?.data.utf8.elementsEqual("{\"type\":\n\"message_start\",\"text\":\"cafe\u{301}\"}".utf8) == true)
    }
}
