import AgentModels
import Foundation
import XCTest

final class JSONValueTests: XCTestCase {
    func testRejectsNonFiniteNumbersOnEncode() {
        XCTAssertThrowsError(try JSONEncoder().encode(JSONValue.number(.nan)))
    }

    func testScalarTypesStayDistinctAndEmptyContainersSurvive() throws {
        let fixtures: [(String, JSONValue)] = [
            (#""123""#, .string("123")), (#""true""#, .string("true")),
            ("0", .number(0)), ("false", .bool(false)), ("null", .null),
            ("[]", .array([])), ("{}", .object([:])), ("-1.25e2", .number(-125)),
        ]
        for (input, expected) in fixtures {
            let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(input.utf8))
            XCTAssertEqual(decoded, expected)
            XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(decoded)), expected)
        }
    }

    func testNativeJSONPreservesNestedValuesAndLargeNumbers() throws {
        let data = Data(#"{"id":9007199254740993,"price":12.75,"enabled":true,"empty":null,"items":["search",false,{}]}"#.utf8)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case .object(let fields) = value else { return XCTFail("Expected object") }
        XCTAssertEqual(fields["id"], .number(Decimal(string: "9007199254740993")!))
        XCTAssertEqual(fields["price"], .number(Decimal(string: "12.75")!))
        XCTAssertEqual(fields["enabled"], .bool(true))
        XCTAssertEqual(fields["empty"], .null)
        XCTAssertEqual(fields["items"], .array([.string("search"), .bool(false), .object([:])]))
        let encoded = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: encoded), value)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["enabled"] as? Bool, true)
        XCTAssertNotNil(object["price"] as? NSNumber)
    }

    func testRejectsTruncatedJSONRatherThanRepairingIt() {
        for input in [#"{"value": "#, "[1,", "undefined", "NaN"] {
            XCTAssertThrowsError(try JSONDecoder().decode(JSONValue.self, from: Data(input.utf8)))
        }
    }
}
