import Foundation

/// Date and money formatting. Flight times from providers are local to each airport and carry no
/// time zone, so they are parsed and shown in UTC: what's printed is the airport's own clock.
enum Fmt {
  private static func formatter(_ format: String, utc: Bool) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = utc ? TimeZone(identifier: "UTC")! : .current
    formatter.dateFormat = format
    return formatter
  }

  /// Search dates (the user's calendar days) as providers want them.
  static let ymd = formatter("yyyy-MM-dd", utc: false)
  static let ym = formatter("yyyy-MM", utc: false)
  private static let naiveSpace = formatter("yyyy-MM-dd HH:mm", utc: true)
  private static let naiveISO = formatter("yyyy-MM-dd'T'HH:mm:ss", utc: true)
  private static let naiveISOShort = formatter("yyyy-MM-dd'T'HH:mm", utc: true)
  private static let naiveDay = formatter("yyyy-MM-dd", utc: true)

  static var utcCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }()

  /// A local airport time: "2026-12-01 08:05", "2026-12-01T08:05:00" or the same with an offset
  /// (the offset is dropped, keeping the local clock time).
  static func naive(_ text: String?) -> Date? {
    guard let text, text.count >= 10 else { return nil }
    if text.contains("T") {
      if text.count >= 19, let date = naiveISO.date(from: String(text.prefix(19))) { return date }
      if text.count >= 16, let date = naiveISOShort.date(from: String(text.prefix(16))) { return date }
    }
    if text.count >= 16, let date = naiveSpace.date(from: String(text.prefix(16))) { return date }
    return naiveDay.date(from: String(text.prefix(10)))
  }

  /// The search calendar day of a local airport time.
  static func day(ofNaive date: Date) -> Date? {
    ymd.date(from: naiveDay.string(from: date))
  }

  static let time: DateFormatter = {
    let formatter = DateFormatter()
    formatter.timeZone = TimeZone(identifier: "UTC")!
    formatter.timeStyle = .short
    formatter.dateStyle = .none
    return formatter
  }()

  static let naiveDayShort: DateFormatter = {
    let formatter = DateFormatter()
    formatter.timeZone = TimeZone(identifier: "UTC")!
    formatter.setLocalizedDateFormatFromTemplate("EEEdMMM")
    return formatter
  }()

  static let dayShort: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("EEEdMMM")
    return formatter
  }()

  static let dayNumber: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("d")
    return formatter
  }()

  static let weekday: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("EEE")
    return formatter
  }()

  static func money(_ value: Double, _ currency: String) -> String {
    value.formatted(.currency(code: currency).precision(.fractionLength(0)))
  }

  static func duration(_ minutes: Int) -> String {
    let hours = minutes / 60
    let rest = minutes % 60
    if hours == 0 { return "\(rest)m" }
    return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
  }

  /// ISO 8601 durations such as "PT5H30M" or "P1DT2H".
  static func isoDurationMinutes(_ text: String?) -> Int? {
    guard let text, text.hasPrefix("P") else { return nil }
    var minutes = 0
    var number = ""
    var inTime = false
    for character in text.dropFirst() {
      if character == "T" { inTime = true; continue }
      if character.isNumber { number.append(character); continue }
      let value = Int(number) ?? 0
      number = ""
      switch character {
      case "D": minutes += value * 1440
      case "H": minutes += value * 60
      case "M": minutes += inTime ? value : value * 43_200
      case "W": minutes += value * 10_080
      default: break
      }
    }
    return minutes
  }

  static func days(from start: Date, to end: Date) -> Int {
    let calendar = Calendar.current
    return calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: end)).day ?? 0
  }

  static func addDays(_ days: Int, to date: Date) -> Date {
    Calendar.current.date(byAdding: .day, value: days, to: date) ?? date
  }
}
