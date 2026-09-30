import Testing
import Foundation
import AgentModels
@testable import AgentProviders

struct RetryAfterDateTests {
    private let now = Date(timeIntervalSince1970: 784_111_767) // Sun 6 Nov 1994 08:49:27 GMT
    @Test(arguments: ["Sun, 06 Nov 1994 08:49:37 GMT", "Sunday, 06-Nov-94 08:49:37 GMT", "Sun Nov  6 08:49:37 1994"])
    func allHTTPDateFormatsUseControlledUTC(_ text: String) {
        #expect(ProviderHTTPFailure.classify(429, headers: ["rEtRy-AfTeR": text], now: now).retryAfter == .seconds(10))
    }
    @Test func decimalAndPastValues() {
        for text in ["0", " 0\t", "Sun, 06 Nov 1994 08:49:26 GMT"] {
            #expect(ProviderRetryAfter.parse(text, now: now) == .zero)
        }
        #expect(ProviderRetryAfter.parse("00017", now: now) == .seconds(17))
        #expect(ProviderRetryAfter.parse(String(Int64.max), now: now) == .seconds(Int64.max))
    }
    @Test(arguments: ["", "-1", "+1", "1.5", "9223372036854775808", "9999999999999999999999999", "∞", "Sun, 32 Nov 1994 08:49:37 GMT", "Sun, 06 Nov 1994 08:49:37 PST", "Sun, 06 Nov 1994 08:49:37 GMT junk", "1\r\n2"])
    func invalidNegativeAndOverflowValuesAreIgnored(_ text: String) {
        #expect(ProviderRetryAfter.parse(text, now: now) == nil)
    }
    @Test func obsoleteTwoDigitDateUsesFiftyYearRule() {
        let reference = Date(timeIntervalSince1970: 1_577_836_800) // 2020-01-01
        #expect(ProviderRetryAfter.parse("Tuesday, 06-Nov-90 08:49:37 GMT", now: reference) == .zero)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEEE, dd-MMM-yy HH:mm:ss 'GMT'"
        let target = Date(timeIntervalSince1970: 1_893_456_000) // 2030-01-01
        #expect(ProviderRetryAfter.parse(formatter.string(from: target), now: reference) == .seconds(target.timeIntervalSince(reference)))
    }
}
