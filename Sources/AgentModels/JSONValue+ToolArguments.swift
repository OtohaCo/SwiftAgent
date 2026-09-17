import Foundation

extension JSONValue {
    package static func decodeToolArguments(_ text: String) throws -> JSONValue {
        guard !containsTrailingComma(text),
              !containsAmbiguousKeys(text),
              let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)),
              case .object = value else {
            throw ToolArgumentDecodingError.invalidObject
        }
        return value
    }

    // Reject keys that Swift dictionaries would merge, including escaped spellings
    // and canonically equivalent Unicode. Decode string tokens with Foundation.
    private static func containsAmbiguousKeys(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        var scopes: [Set<String>?] = []
        var index = 0
        while index < bytes.count {
            switch bytes[index] {
            case 0x7B: scopes.append([])
            case 0x5B: scopes.append(nil)
            case 0x7D, 0x5D:
                if !scopes.isEmpty { scopes.removeLast() }
            case 0x22:
                let start = index
                index += 1
                while index < bytes.count {
                    if bytes[index] == 0x5C { index += 2; continue }
                    if bytes[index] == 0x22 { break }
                    index += 1
                }
                guard index < bytes.count else { return true }
                var next = index + 1
                while next < bytes.count && [0x20, 0x09, 0x0A, 0x0D].contains(bytes[next]) { next += 1 }
                if next < bytes.count, bytes[next] == 0x3A, !scopes.isEmpty,
                   var keys = scopes[scopes.count - 1] {
                    guard let key = try? JSONDecoder().decode(String.self, from: Data(bytes[start...index])),
                          keys.insert(key).inserted else { return true }
                    scopes[scopes.count - 1] = keys
                }
            default: break
            }
            index += 1
        }
        return false
    }

    // Foundation accepts trailing commas. Check only that extension here;
    // JSONDecoder remains responsible for the rest of the JSON grammar.
    private static func containsTrailingComma(_ json: String) -> Bool {
        var insideString = false
        var escaped = false
        var previous: UInt8?
        for byte in json.utf8 {
            if insideString {
                if escaped { escaped = false }
                else if byte == 0x5C { escaped = true }
                else if byte == 0x22 { insideString = false }
                continue
            }
            switch byte {
            case 0x20, 0x09, 0x0A, 0x0D: continue
            case 0x22: insideString = true
            case 0x5D, 0x7D:
                if previous == 0x2C { return true }
            default: break
            }
            previous = byte
        }
        return false
    }
}

private enum ToolArgumentDecodingError: Error { case invalidObject }
