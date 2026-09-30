import Foundation

/// RFC 9110 sections 5.6.7 and 10.2.3. Parsing is UTC/POSIX, never the Host locale.
enum ProviderRetryAfter {
    static func parse(_ raw: String, now: Date) -> Duration? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text.utf8.count <= 128 else { return nil }
        if text.utf8.allSatisfy({ (48...57).contains($0) }) {
            guard let seconds = Int64(text) else { return nil }
            return .seconds(seconds)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.isLenient = false
        let formats = ["EEE, dd MMM yyyy HH:mm:ss 'GMT'", "EEEE, dd-MMM-yy HH:mm:ss 'GMT'", "EEE MMM dd HH:mm:ss yyyy"]
        for (index, format) in formats.enumerated() {
            formatter.dateFormat = format
            // Use the current century, then apply RFC850's exact 50-year rule.
            if index == 1 {
                let century = calendar.component(.year, from: now) / 100 * 100
                formatter.twoDigitStartDate = calendar.date(from: .init(year: century, month: 1, day: 1))
            }
            var input = text
            if index == 2, input.count == 24 {
                let day = input.index(input.startIndex, offsetBy: 8)
                if input[day] == " " { input.replaceSubrange(day...day, with: "0") }
            }
            let leapSecond = input.range(of: "[0-9]{2}:[0-9]{2}:60", options: .regularExpression)
            if let range = leapSecond {
                input.replaceSubrange(range, with: String(input[range].prefix(6)) + "59")
            }
            guard var date = formatter.date(from: input) else { continue }
            if index == 1, date < now, let nextCentury = calendar.date(byAdding: .year, value: 100, to: date) {
                date = nextCentury
            }
            if index == 1, let horizon = calendar.date(byAdding: .year, value: 50, to: now), date > horizon {
                guard let adjusted = calendar.date(byAdding: .year, value: -100, to: date) else { return nil }
                date = adjusted
            }
            guard formatter.string(from: date) == input else { continue }
            if leapSecond != nil { date = date.addingTimeInterval(1) }
            let delay = max(0, date.timeIntervalSince(now))
            guard delay.isFinite else { return nil }
            return .seconds(delay)
        }
        return nil
    }
}
