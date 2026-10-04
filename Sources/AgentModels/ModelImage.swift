import Foundation

/// An image a model may look at: Host-supplied bytes with their media type, immutable content identity
/// (SHA-256 of the bytes) and a short text alternative. The SDK never downloads, resolves paths or
/// performs OCR; it only checks type, size and the text alternative.
///
/// Adapters send the bytes only when both the model and the adapter accept images; otherwise the Run's
/// explicit image policy decides between a failure before dispatch and `textSubstitute`.
public struct ModelImage: Hashable, Sendable, Codable {
    public enum MediaType: String, Hashable, Sendable, Codable, CaseIterable {
        case png = "image/png"
        case jpeg = "image/jpeg"
        case gif = "image/gif"
        case webp = "image/webp"

        var shortName: String {
            switch self {
            case .png: "PNG"
            case .jpeg: "JPEG"
            case .gif: "GIF"
            case .webp: "WebP"
            }
        }
    }

    /// The largest image accepted, in bytes: the smallest per-image limit of the adapters that send images.
    public static let maximumByteCount = 5 * 1024 * 1024
    /// The most images one message (a user turn or one tool result) may carry.
    public static let maximumImagesPerMessage = 8
    /// The longest text alternative, in UTF-8 bytes.
    public static let maximumDescriptionBytes = 1_024
    /// The estimate used when the pixel size cannot be read from the header.
    public static let unknownSizeTokenEstimate = 1_600
    /// Set to `true` in an encoder's `userInfo` to encode an image as its identity and metadata only,
    /// for size measurement and digests. Such an encoding cannot be decoded back into an image.
    public static let referenceOnlyEncoding = CodingUserInfoKey(rawValue: "SwiftAgent.ModelImage.referenceOnly")!

    public let mediaType: MediaType
    public let data: Data
    /// Lowercase hexadecimal SHA-256 of `data`.
    public let digest: String
    /// Short text alternative, used where the image itself is not sent.
    public let description: String
    public let pixelWidth: Int?
    public let pixelHeight: Int?

    public var byteCount: Int { data.count }

    /// Checks the bytes against `mediaType` (or recognizes the type when nil), the size limit and the
    /// text alternative.
    public init(data: Data, mediaType: MediaType? = nil, description: String) throws {
        let header = try Self.validate(data: data, mediaType: mediaType, description: description)
        self.init(verified: data, mediaType: header.type, description: description,
                  digest: ModelImageDigest.sha256Hex(data), size: header.size)
    }

    /// For stores that have already verified `digest` over `data` with their own hash implementation.
    package init(data: Data, mediaType: MediaType, description: String, verifiedDigest: String) throws {
        let header = try Self.validate(data: data, mediaType: mediaType, description: description)
        guard Self.validDigest(verifiedDigest) else { throw ModelImageError.digestMismatch }
        self.init(verified: data, mediaType: header.type, description: description,
                  digest: verifiedDigest, size: header.size)
    }

    private init(verified data: Data, mediaType: MediaType, description: String, digest: String,
                 size: (width: Int, height: Int)?) {
        self.mediaType = mediaType
        self.data = data
        self.digest = digest
        self.description = description
        pixelWidth = size?.width
        pixelHeight = size?.height
    }

    /// What a model that does not see this image reads instead.
    public var textSubstitute: String {
        var detail = mediaType.shortName
        if let pixelWidth, let pixelHeight { detail += ", \(pixelWidth)×\(pixelHeight)" }
        return "[Image not shown: \(description) (\(detail))]"
    }

    /// A conservative input-token estimate across the adapters that send images: the larger of the
    /// Anthropic pixel-area rule and the OpenAI high-detail tile rule. Unknown size uses
    /// `unknownSizeTokenEstimate`. Providers' actual accounting may differ.
    public var estimatedInputTokens: Int {
        guard let width = pixelWidth, let height = pixelHeight, width > 0, height > 0 else {
            return Self.unknownSizeTokenEstimate
        }
        return max(Self.anthropicEstimate(width, height), Self.openAIHighDetailEstimate(width, height))
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.digest == rhs.digest && lhs.mediaType == rhs.mediaType
            && lhs.description.utf8.elementsEqual(rhs.description.utf8)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(digest)
        hasher.combine(Array(description.utf8))
    }

    private enum CodingKeys: String, CodingKey {
        case mediaType, digest, byteCount, description, pixelWidth, pixelHeight, data
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let data = try container.decode(Data.self, forKey: .data)
        let image = try ModelImage(data: data, mediaType: container.decode(MediaType.self, forKey: .mediaType),
                                   description: container.decode(String.self, forKey: .description))
        guard image.digest == (try container.decode(String.self, forKey: .digest)) else {
            throw DecodingError.dataCorruptedError(forKey: .digest, in: container,
                                                   debugDescription: "Image bytes do not match their digest.")
        }
        self = image
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mediaType, forKey: .mediaType)
        try container.encode(digest, forKey: .digest)
        try container.encode(byteCount, forKey: .byteCount)
        try container.encode(description, forKey: .description)
        try container.encodeIfPresent(pixelWidth, forKey: .pixelWidth)
        try container.encodeIfPresent(pixelHeight, forKey: .pixelHeight)
        if encoder.userInfo[Self.referenceOnlyEncoding] as? Bool != true {
            try container.encode(data, forKey: .data)
        }
    }

    private static func validate(data: Data, mediaType: MediaType?, description: String) throws
        -> (type: MediaType, size: (width: Int, height: Int)?) {
        guard !data.isEmpty else { throw ModelImageError.empty }
        guard data.count <= maximumByteCount else {
            throw ModelImageError.tooLarge(byteCount: data.count, limit: maximumByteCount)
        }
        guard !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              description.utf8.count <= maximumDescriptionBytes else {
            throw ModelImageError.invalidDescription
        }
        let bytes = [UInt8](data.prefix(64 * 1024))
        guard let actual = ModelImageHeader.mediaType(bytes) else { throw ModelImageError.unrecognizedData }
        if let mediaType, mediaType != actual {
            throw ModelImageError.mediaTypeMismatch(declared: mediaType, actual: actual)
        }
        return (actual, ModelImageHeader.size(bytes, type: actual))
    }

    private static func validDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func anthropicEstimate(_ width: Int, _ height: Int) -> Int {
        var w = Double(width), h = Double(height)
        let edge = 1_568.0 / max(w, h)
        if edge < 1 { w *= edge; h *= edge }
        let area = 1_150_000.0 / (w * h)
        if area < 1 { w *= area.squareRoot(); h *= area.squareRoot() }
        return Int((w * h / 750).rounded(.up))
    }

    private static func openAIHighDetailEstimate(_ width: Int, _ height: Int) -> Int {
        var w = Double(width), h = Double(height)
        let fit = 2_048.0 / max(w, h)
        if fit < 1 { w *= fit; h *= fit }
        let short = 768.0 / min(w, h)
        if short < 1 { w *= short; h *= short }
        let tiles = Int((w / 512).rounded(.up)) * Int((h / 512).rounded(.up))
        return 85 + 170 * tiles
    }
}

public enum ModelImageError: Error, Equatable, Sendable {
    case empty
    case tooLarge(byteCount: Int, limit: Int)
    case unrecognizedData
    case mediaTypeMismatch(declared: ModelImage.MediaType, actual: ModelImage.MediaType)
    case invalidDescription
    case digestMismatch
    case tooManyImages(count: Int, limit: Int)
}

extension ModelContent {
    /// The image's token estimate, or 0 for content that is not an image.
    public var estimatedImageInputTokens: Int {
        if case .image(let image) = self { return image.estimatedInputTokens }
        return 0
    }
}

extension ModelMessage {
    /// Images carried by this message's content or tool result.
    public var images: [ModelImage] {
        let content: [ModelContent]
        switch self {
        case .system, .developer: return []
        case .user(let parts): content = parts
        case .assistant(let parts, _): content = parts
        case .tool(let result): content = result.content
        }
        return content.compactMap { if case .image(let image) = $0 { image } else { nil } }
    }
}

/// Recognizes supported images by their leading bytes and reads the pixel size from the header.
enum ModelImageHeader {
    static func mediaType(_ b: [UInt8]) -> ModelImage.MediaType? {
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .png }
        if b.starts(with: [0xFF, 0xD8, 0xFF]) { return .jpeg }
        if b.starts(with: Array("GIF87a".utf8)) || b.starts(with: Array("GIF89a".utf8)) { return .gif }
        if b.count >= 12, b.starts(with: Array("RIFF".utf8)), Array(b[8..<12]) == Array("WEBP".utf8) { return .webp }
        return nil
    }

    static func size(_ b: [UInt8], type: ModelImage.MediaType) -> (width: Int, height: Int)? {
        let size: (Int, Int)?
        switch type {
        case .png:
            size = b.count >= 24 && Array(b[12..<16]) == Array("IHDR".utf8) ? (be32(b, 16), be32(b, 20)) : nil
        case .gif:
            size = b.count >= 10 ? (Int(b[6]) | Int(b[7]) << 8, Int(b[8]) | Int(b[9]) << 8) : nil
        case .webp:
            size = webp(b)
        case .jpeg:
            size = jpeg(b)
        }
        guard let size, size.0 > 0, size.1 > 0, size.0 <= 1 << 20, size.1 <= 1 << 20 else { return nil }
        return size
    }

    private static func be32(_ b: [UInt8], _ i: Int) -> Int {
        Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
    }

    private static func webp(_ b: [UInt8]) -> (Int, Int)? {
        guard b.count >= 30 else { return nil }
        switch String(decoding: b[12..<16], as: UTF8.self) {
        case "VP8X":
            return (1 + (Int(b[24]) | Int(b[25]) << 8 | Int(b[26]) << 16),
                    1 + (Int(b[27]) | Int(b[28]) << 8 | Int(b[29]) << 16))
        case "VP8L":
            guard b[20] == 0x2F else { return nil }
            let bits = Int(b[21]) | Int(b[22]) << 8 | Int(b[23]) << 16 | Int(b[24]) << 24
            return (1 + bits & 0x3FFF, 1 + (bits >> 14) & 0x3FFF)
        case "VP8 ":
            guard b[23] == 0x9D, b[24] == 0x01, b[25] == 0x2A else { return nil }
            return ((Int(b[26]) | Int(b[27]) << 8) & 0x3FFF, (Int(b[28]) | Int(b[29]) << 8) & 0x3FFF)
        default:
            return nil
        }
    }

    private static func jpeg(_ b: [UInt8]) -> (Int, Int)? {
        var i = 2
        while i + 9 < b.count {
            guard b[i] == 0xFF else { return nil }
            let marker = b[i + 1]
            if marker == 0xFF { i += 1; continue }
            if marker == 0xD8 || marker == 0x01 || (0xD0...0xD7).contains(marker) { i += 2; continue }
            if marker == 0xD9 || marker == 0xDA { return nil }
            let length = Int(b[i + 2]) << 8 | Int(b[i + 3])
            if (0xC0...0xCF).contains(marker), ![0xC4, 0xC8, 0xCC].contains(marker) {
                return (Int(b[i + 7]) << 8 | Int(b[i + 8]), Int(b[i + 5]) << 8 | Int(b[i + 6]))
            }
            guard length >= 2 else { return nil }
            i += 2 + length
        }
        return nil
    }
}

/// SHA-256 without a crypto dependency: AgentModels has none (FIPS 180-4).
package enum ModelImageDigest {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    package static func sha256Hex(_ data: Data) -> String {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                           0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var tail = [UInt8]()
        let whole = data.count / 64 * 64
        var w = [UInt32](repeating: 0, count: 64)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < whole {
                block(raw, at: offset, into: &h, schedule: &w)
                offset += 64
            }
            tail = Array(raw[whole..<raw.count])
        }
        tail.append(0x80)
        while tail.count % 64 != 56 { tail.append(0) }
        let bits = UInt64(data.count) &* 8
        for shift in stride(from: 56, through: 0, by: -8) { tail.append(UInt8(truncatingIfNeeded: bits >> UInt64(shift))) }
        tail.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                block(raw, at: offset, into: &h, schedule: &w)
                offset += 64
            }
        }
        let hex = Array("0123456789abcdef".utf8)
        var out = [UInt8](); out.reserveCapacity(64)
        for word in h {
            for shift in stride(from: 28, through: 0, by: -4) { out.append(hex[Int((word >> UInt32(shift)) & 0xF)]) }
        }
        return String(decoding: out, as: UTF8.self)
    }

    @inline(__always)
    private static func block(_ raw: UnsafeRawBufferPointer, at offset: Int, into h: inout [UInt32],
                              schedule w: inout [UInt32]) {
        for i in 0..<16 {
            let p = offset + i * 4
            w[i] = UInt32(raw[p]) << 24 | UInt32(raw[p + 1]) << 16 | UInt32(raw[p + 2]) << 8 | UInt32(raw[p + 3])
        }
        for i in 16..<64 {
            let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
            let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
        }
        var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
        for i in 0..<64 {
            let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
            let ch = (e & f) ^ (~e & g)
            let t1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
            let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let t2 = s0 &+ maj
            hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
        }
        h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
        h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
    }

    @inline(__always)
    private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
}
