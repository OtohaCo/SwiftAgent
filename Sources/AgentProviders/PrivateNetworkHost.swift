import Foundation

/// Hosts on this computer or on the network around it, where a Host may choose to accept plain HTTP.
///
/// Stricter than a prefix test: `10.example.com` and `192.168.1.10.example.com` are names on the internet, and only an
/// IPv4 address written out in full, a `.local` name or a loopback host counts.
enum PrivateNetworkHost {
    static func isLoopback(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }

    static func isPrivate(_ host: String?) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        if isLoopback(host) { return true }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        if labels.count >= 2, labels.last == "local", labels.allSatisfy({ !$0.isEmpty }) { return true }
        guard labels.count == 4 else { return false }
        var numbers: [Int] = []
        for label in labels {
            guard !label.isEmpty, label.count <= 3, label.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  let number = Int(label), number <= 255 else { return false }
            numbers.append(number)
        }
        switch (numbers[0], numbers[1]) {
        case (10, _), (192, 168): return true
        case (172, 16...31): return true
        default: return false
        }
    }
}
