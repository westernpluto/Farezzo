import Foundation

/// Skyscanner links: the same search, already filled in, opened on Skyscanner. (Skyscanner's
/// results page shows a "press and hold" robot check to automated browsers before any results,
/// so it's opened for the person to read rather than read by the app.)
enum Skyscanner {
  /// Skyscanner's own codes for cities with several airports; other places use the airport code.
  private static let cityCodes: [String: String] = [
    "NYC": "nyca", "LON": "lond", "PAR": "pari", "CHI": "chia", "WAS": "wasa", "MIL": "mila",
    "ROM": "rome", "TYO": "tyoa",
  ]

  static func code(for place: Place) -> String {
    if let code = cityCodes[place.code] { return code }
    if place.kind == .city, let first = Airports.metro[place.code]?.first { return first.lowercased() }
    return place.code.lowercased()
  }

  private static let dateFormat: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.dateFormat = "yyMMdd"
    return formatter
  }()

  private static func cabin(_ cabin: Cabin) -> String {
    switch cabin {
    case .economy: return "economy"
    case .premiumEconomy: return "premiumeconomy"
    case .business: return "business"
    case .first: return "first"
    }
  }

  static func url(from: String, to: String, depart: Date, ret: Date?, query: SearchQuery) -> URL {
    var path = "https://www.skyscanner.com/transport/flights/\(from.lowercased())/\(to.lowercased())/\(dateFormat.string(from: depart))/"
    if let ret { path += "\(dateFormat.string(from: ret))/" }
    var params: [(String, String)] = [
      ("adultsv2", "\(max(1, query.adults))"),
      ("cabinclass", cabin(query.cabin)),
      ("rtn", ret == nil ? "0" : "1"),
      ("preferdirects", query.maxStops == 0 ? "true" : "false"),
      ("currency", query.currency.uppercased()),
    ]
    if query.children > 0 {
      params.append(("childrenv2", Array(repeating: "10", count: query.children).joined(separator: "|")))
    }
    return HTTP.url(path, params)
  }

  /// The whole search (every airport in the city), for the results screen.
  static func url(for query: SearchQuery) -> URL? {
    guard let origin = query.origin, let destination = query.destination else { return nil }
    return url(from: code(for: origin), to: code(for: destination), depart: query.departDate, ret: query.returnDate, query: query)
  }
}
