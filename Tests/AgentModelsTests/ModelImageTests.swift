import AgentModels
import Foundation
import XCTest

/// Image bytes for tests: real headers, as far as the SDK reads them.
enum ImageFixture {
    static func png(width: Int, height: Int, padding: Int = 0) -> Data {
        var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13])
        data.append(contentsOf: Array("IHDR".utf8))
        data.append(contentsOf: bigEndian(width)); data.append(contentsOf: bigEndian(height))
        data.append(contentsOf: [8, 2, 0, 0, 0, 0, 0, 0, 0])
        data.append(Data(repeating: 0x5A, count: padding))
        data.append(contentsOf: [0, 0, 0, 0]); data.append(contentsOf: Array("IEND".utf8))
        data.append(contentsOf: [0xAE, 0x42, 0x60, 0x82])
        return data
    }

    static func jpeg(width: Int, height: Int) -> Data {
        var data = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
        data.append(contentsOf: Array("JFIF".utf8)); data.append(contentsOf: [0, 1, 1, 0, 0, 1, 0, 1, 0, 0])
        data.append(contentsOf: [0xFF, 0xC0, 0x00, 0x11, 0x08])
        data.append(contentsOf: bigEndian(height).suffix(2)); data.append(contentsOf: bigEndian(width).suffix(2))
        data.append(contentsOf: [0x03, 0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01, 0xFF, 0xD9])
        return data
    }

    static func gif(width: Int, height: Int) -> Data {
        var data = Data(Array("GIF89a".utf8))
        data.append(contentsOf: [UInt8(width & 0xFF), UInt8(width >> 8), UInt8(height & 0xFF), UInt8(height >> 8)])
        data.append(contentsOf: [0, 0, 0, 0x3B])
        return data
    }

    static func webpLossless(width: Int, height: Int) -> Data {
        var data = Data(Array("RIFF".utf8)); data.append(contentsOf: [30, 0, 0, 0])
        data.append(contentsOf: Array("WEBPVP8L".utf8)); data.append(contentsOf: [10, 0, 0, 0, 0x2F])
        let bits = UInt32(width - 1) | (UInt32(height - 1) << 14)
        data.append(contentsOf: [UInt8(bits & 0xFF), UInt8((bits >> 8) & 0xFF), UInt8((bits >> 16) & 0xFF), UInt8((bits >> 24) & 0xFF)])
        data.append(contentsOf: [0, 0, 0, 0, 0])
        return data
    }

    private static func bigEndian(_ value: Int) -> [UInt8] {
        [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }
}

final class ModelImageTests: XCTestCase {
    func testDigestIsTheSHA256OfTheBytes() {
        XCTAssertEqual(ModelImageDigest.sha256Hex(Data()),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(ModelImageDigest.sha256Hex(Data("abc".utf8)),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(ModelImageDigest.sha256Hex(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        XCTAssertEqual(ModelImageDigest.sha256Hex(Data(repeating: 0x61, count: 1_000)),
                       "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
    }

    func testAnImageKnowsItsTypeSizeAndIdentityFromItsBytes() throws {
        let data = ImageFixture.png(width: 1280, height: 720)
        let image = try ModelImage(data: data, description: "The exported video's first frame")
        XCTAssertEqual(image.mediaType, .png)
        XCTAssertEqual(image.byteCount, data.count)
        XCTAssertEqual(image.pixelWidth, 1280)
        XCTAssertEqual(image.pixelHeight, 720)
        XCTAssertEqual(image.digest, ModelImageDigest.sha256Hex(data))
        XCTAssertEqual(image.data, data)

        let jpeg = try ModelImage(data: ImageFixture.jpeg(width: 640, height: 480), mediaType: .jpeg, description: "photo")
        XCTAssertEqual([jpeg.pixelWidth, jpeg.pixelHeight], [640, 480])
        let gif = try ModelImage(data: ImageFixture.gif(width: 32, height: 16), description: "icon")
        XCTAssertEqual(gif.mediaType, .gif)
        XCTAssertEqual([gif.pixelWidth, gif.pixelHeight], [32, 16])
        let webp = try ModelImage(data: ImageFixture.webpLossless(width: 300, height: 200), description: "chart")
        XCTAssertEqual(webp.mediaType, .webp)
        XCTAssertEqual([webp.pixelWidth, webp.pixelHeight], [300, 200])
    }

    func testBytesThatAreNotASupportedImageAreRefused() {
        XCTAssertThrowsError(try ModelImage(data: Data(), description: "x")) {
            XCTAssertEqual($0 as? ModelImageError, .empty)
        }
        XCTAssertThrowsError(try ModelImage(data: Data("not an image".utf8), description: "x")) {
            XCTAssertEqual($0 as? ModelImageError, .unrecognizedData)
        }
        XCTAssertThrowsError(try ModelImage(data: ImageFixture.png(width: 2, height: 2), mediaType: .jpeg, description: "x")) {
            XCTAssertEqual($0 as? ModelImageError, .mediaTypeMismatch(declared: .jpeg, actual: .png))
        }
    }

    func testAnImageOverTheSizeLimitIsRefused() {
        let data = ImageFixture.png(width: 4000, height: 4000, padding: ModelImage.maximumByteCount)
        XCTAssertThrowsError(try ModelImage(data: data, description: "x")) {
            XCTAssertEqual($0 as? ModelImageError, .tooLarge(byteCount: data.count, limit: ModelImage.maximumByteCount))
        }
    }

    func testTheDescriptionIsRequiredAndBounded() {
        let png = ImageFixture.png(width: 2, height: 2)
        XCTAssertThrowsError(try ModelImage(data: png, description: "  \n")) {
            XCTAssertEqual($0 as? ModelImageError, .invalidDescription)
        }
        XCTAssertThrowsError(try ModelImage(data: png, description: String(repeating: "a", count: ModelImage.maximumDescriptionBytes + 1))) {
            XCTAssertEqual($0 as? ModelImageError, .invalidDescription)
        }
    }

    func testTheTextSubstituteSaysWhatTheImageWasWithoutItsBytes() throws {
        let image = try ModelImage(data: ImageFixture.png(width: 1280, height: 720), description: "Settings window")
        XCTAssertEqual(image.textSubstitute, "[Image not shown: Settings window (PNG, 1280×720)]")
        let unknownSize = try ModelImage(data: Data([0xFF, 0xD8, 0xFF, 0xD9]), description: "photo")
        XCTAssertEqual(unknownSize.textSubstitute, "[Image not shown: photo (JPEG)]")
    }

    func testTokenEstimateGrowsWithPixelsAndIsConservativeWhenUnknown() throws {
        let small = try ModelImage(data: ImageFixture.png(width: 200, height: 200), description: "s")
        let large = try ModelImage(data: ImageFixture.png(width: 1920, height: 1080), description: "l")
        let unknown = try ModelImage(data: Data([0xFF, 0xD8, 0xFF, 0xD9]), description: "u")
        XCTAssertGreaterThan(small.estimatedInputTokens, 0)
        XCTAssertGreaterThan(large.estimatedInputTokens, small.estimatedInputTokens)
        XCTAssertGreaterThanOrEqual(unknown.estimatedInputTokens, large.estimatedInputTokens)
        XCTAssertEqual(ModelContent.image(large).estimatedImageInputTokens, large.estimatedInputTokens)
    }

    func testCodableRoundTripKeepsTheBytesAndChecksThem() throws {
        let image = try ModelImage(data: ImageFixture.png(width: 8, height: 8), description: "tile")
        let message = ModelMessage.tool(.init(callID: .init(rawValue: "c"), content: [.json(.null), .image(image)], isError: false))
        let restored = try JSONDecoder().decode(ModelMessage.self, from: JSONEncoder().encode(message))
        XCTAssertEqual(restored, message)
        guard case .tool(let result) = restored, case .image(let back) = result.content[1] else { return XCTFail() }
        XCTAssertEqual(back.data, image.data)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(image)) as? [String: Any])
        object["digest"] = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try JSONDecoder().decode(ModelImage.self, from: JSONSerialization.data(withJSONObject: object)))
    }

    func testReferenceEncodingCarriesTheDigestButNotTheBytes() throws {
        let image = try ModelImage(data: ImageFixture.png(width: 8, height: 8, padding: 4_096), description: "tile")
        let encoder = JSONEncoder()
        encoder.userInfo[ModelImage.referenceOnlyEncoding] = true
        let reference = try encoder.encode([ModelContent.image(image)])
        let text = String(decoding: reference, as: UTF8.self)
        XCTAssertTrue(text.contains(image.digest))
        XCTAssertFalse(text.contains(image.data.base64EncodedString()))
        XCTAssertLessThan(reference.count, 512)
        XCTAssertThrowsError(try JSONDecoder().decode([ModelContent].self, from: reference))
    }

    func testEqualityFollowsIdentityAndDescription() throws {
        let data = ImageFixture.png(width: 8, height: 8)
        XCTAssertEqual(try ModelImage(data: data, description: "a"), try ModelImage(data: data, description: "a"))
        XCTAssertNotEqual(try ModelImage(data: data, description: "a"), try ModelImage(data: data, description: "b"))
        XCTAssertNotEqual(try ModelImage(data: data, description: "a"),
                          try ModelImage(data: ImageFixture.png(width: 9, height: 8), description: "a"))
    }

    func testImageInputIsADistinctAdapterCapability() {
        XCTAssertFalse(ModelCapabilities([.streaming, .multiTurn, .tools, .structuredOutput, .reasoning]).contains(.imageInput))
    }
}
