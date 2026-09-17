import CryptoKit
import Foundation

enum WorkspaceContentHash {
    static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func hex(_ text: String) -> String {
        hex(Data(text.utf8))
    }
}
