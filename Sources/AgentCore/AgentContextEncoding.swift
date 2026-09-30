import Foundation
import AgentModels

// Package-only observation of actual message encoding buffers. Task-local
// ownership keeps measurements isolated across concurrent Runs/tests.
package enum AgentContextEncodingObservation {
    @TaskLocal package static var didEncode: (@Sendable (String, Int) -> Void)?
}

package struct AgentContextSourceEncoding: Sendable {
    let digest: String
    let byteCount: Int
}

// Only an unchanged COW array can reuse its source size. Value equality is
// insufficient: canonically equivalent Swift Strings can encode different UTF-8.
package func sharesCanonicalMessageStorage(_ lhs: [ModelMessage], _ rhs: [ModelMessage]) -> Bool {
    guard lhs.count == rhs.count else { return false }
    return lhs.withUnsafeBufferPointer { left in
        rhs.withUnsafeBufferPointer { right in left.baseAddress == right.baseAddress }
    }
}
