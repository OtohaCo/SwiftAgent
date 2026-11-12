#if canImport(Darwin) || os(Linux)
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A real HTTP/1.1 server, bound only to an ephemeral loopback port. Responses
/// stay open until the test sends the final SSE event; no wall-clock pacing.
final class TransportLoopbackServer: @unchecked Sendable {
    struct Request: Sendable {
        let path: String
        let headers: [String: String]
    }

    private final class Connection {
        let descriptor: Int32
        let source: any DispatchSourceRead
        var head = Data()
        var path: String?
        init(_ descriptor: Int32, queue: DispatchQueue) {
            self.descriptor = descriptor
            source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            source.setCancelHandler { _ = close(descriptor) }
        }
    }

    private let queue = DispatchQueue(label: "transport-loopback-server")
    private let listener: any DispatchSourceRead
    private var connections: [Int32: Connection] = [:]
    private var captured: [Request] = []
    private var disconnected: Set<String> = []
    let port: UInt16

    init() throws {
        #if canImport(Darwin)
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let descriptor = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard descriptor >= 0 else { throw SocketFailure(operation: "socket", code: errno) }
        var ownsDescriptor = true
        defer { if ownsDescriptor { _ = close(descriptor) } }
        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(descriptor, 8) == 0,
              fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else {
            throw SocketFailure(operation: "listen", code: errno)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard named == 0 else { throw SocketFailure(operation: "getsockname", code: errno) }
        port = UInt16(bigEndian: address.sin_port)
        listener = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        listener.setEventHandler { [weak self] in self?.acceptConnections(descriptor) }
        listener.setCancelHandler { _ = close(descriptor) }
        ownsDescriptor = false
        listener.resume()
    }

    var requests: [Request] { queue.sync { captured } }
    var disconnectedPaths: Set<String> { queue.sync { disconnected } }

    func request(_ path: String, authorization: String? = nil) -> URLRequest {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        return request
    }

    func finish(_ path: String, event: String) throws {
        try queue.sync {
            guard let connection = connections.values.first(where: { $0.path == path }) else {
                throw SocketFailure(operation: "missing request \(path)", code: 0)
            }
            try write(Self.chunk("data: \(event)\n\n") + Data("0\r\n\r\n".utf8), to: connection.descriptor)
            remove(connection.descriptor)
        }
    }

    func stop() {
        queue.sync {
            listener.cancel()
            for connection in connections.values { connection.source.cancel() }
            connections.removeAll()
        }
    }

    private func acceptConnections(_ descriptor: Int32) {
        while true {
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else { return }
            // Bound writes and suppress SIGPIPE if cancellation closes the peer.
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            _ = setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            #if canImport(Darwin)
            var enabled: Int32 = 1
            _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
            #endif
            let connection = Connection(client, queue: queue)
            connections[client] = connection
            connection.source.setEventHandler { [weak self] in self?.readRequest(client) }
            connection.source.resume()
        }
    }

    private func readRequest(_ descriptor: Int32) {
        guard let connection = connections[descriptor] else { return }
        var bytes = [UInt8](repeating: 0, count: 16_384)
        let count = recv(descriptor, &bytes, bytes.count, 0)
        guard count > 0 else {
            if count < 0 && (errno == EINTR || errno == EAGAIN) { return }
            if let path = connection.path { disconnected.insert(path) }
            remove(descriptor)
            return
        }
        guard connection.path == nil else { return }
        connection.head.append(contentsOf: bytes.prefix(count))
        guard connection.head.count <= 65_536 else { remove(descriptor); return }
        guard let end = connection.head.range(of: Data("\r\n\r\n".utf8)) else { return }
        let lines = String(decoding: connection.head[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        guard let first = lines.first, let path = first.split(separator: " ").dropFirst().first else {
            remove(descriptor); return
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        connection.path = String(path)
        captured.append(Request(path: String(path), headers: headers))
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nSet-Cookie: transport_fixture=stored; Path=/\r\nConnection: close\r\n\r\n"
        do {
            try write(Data(response.utf8) + Self.chunk("data: \(path)-start\n\n"), to: descriptor)
        } catch { remove(descriptor) }
    }

    private func remove(_ descriptor: Int32) { connections.removeValue(forKey: descriptor)?.source.cancel() }

    private static func chunk(_ text: String) -> Data {
        let body = Data(text.utf8)
        return Data("\(String(body.count, radix: 16))\r\n".utf8) + body + Data("\r\n".utf8)
    }

    private func write(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                #if canImport(Darwin)
                let count = Darwin.send(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
                #else
                let count = Glibc.send(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, Int32(MSG_NOSIGNAL))
                #endif
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw SocketFailure(operation: "send", code: errno) }
                offset += count
            }
        }
    }

    private struct SocketFailure: Error { let operation: String; let code: Int32 }
}
#endif
