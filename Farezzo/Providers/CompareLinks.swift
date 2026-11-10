import Foundation

/// The same search, filled in, on other sites, for the airlines and fares the result list can
/// miss. Google Flights doesn't list every airline everywhere (in a November 2026 check it
/// showed no Copa flights at all between Miami and Panama City, Copa's own hub), so trips
/// those airlines fly get a link to the airline's own booking page too.
enum CompareLinks {
  static func links(for query: SearchQuery) -> [BookingLink] {
    guard let origin = query.origin, let destination = query.destination else { return [] }
    var links: [BookingLink] = []
    if let url = Skyscanner.url(for: query) { links.append(BookingLink(label: "Skyscanner", url: url)) }
    links.append(BookingLink(label: "Kayak", url: kayak(query, from: origin, to: destination)))
    if servesLatinAmerica(origin) || servesLatinAmerica(destination) {
      links.append(BookingLink(label: "Copa Airlines", url: copa(query, from: origin, to: destination)))
    }
    return links
  }

  // MARK: Kayak

  static func kayak(_ query: SearchQuery, from: Place, to: Place) -> URL {
    var path = "https://www.kayak.com/flights/\(from.code)-\(to.code)/\(Fmt.ymd.string(from: query.departDate))"
    if let ret = query.returnDate { path += "/\(Fmt.ymd.string(from: ret))" }
    switch query.cabin {
    case .economy: break
    case .premiumEconomy: path += "/premium"
    case .business: path += "/business"
    case .first: path += "/first"
    }
    if query.adults > 1 { path += "/\(query.adults)adults" }
    if query.children > 0 { path += "/children-" + Array(repeating: "10", count: query.children).joined(separator: "-") }
    return HTTP.url(path, [("sort", "price_a")])
  }

  // MARK: Copa Airlines

  /// Copa's booking page takes airports, not cities.
  private static func airport(_ place: Place) -> String {
    place.kind == .city ? (Airports.metro[place.code]?.first ?? place.code) : place.code
  }

  static func copa(_ query: SearchQuery, from: Place, to: Place) -> URL {
    var params: [(String, String)] = [
      ("roundtrip", query.isRoundTrip ? "true" : "false"),
      ("adults", "\(max(1, query.adults))"),
      ("children", "\(query.children)"),
      ("infants", "0"),
      ("date1", Fmt.ymd.string(from: query.departDate)),
    ]
    if let ret = query.returnDate { params.append(("date2", Fmt.ymd.string(from: ret))) }
    params += [("area1", airport(from)), ("area2", airport(to)), ("flexible_dates_v2", "false"), ("langid", "en")]
    return HTTP.url("https://shopping.copaair.com/", params)
  }

  private static let latinAmericaCountries: Set<String> = [
    "mexico", "guatemala", "belize", "honduras", "el salvador", "nicaragua", "costa rica", "panama",
    "colombia", "venezuela", "ecuador", "peru", "bolivia", "chile", "argentina", "uruguay", "paraguay",
    "brazil", "guyana", "suriname", "cuba", "dominican republic", "haiti", "jamaica", "puerto rico",
    "aruba", "curaçao", "curacao", "bahamas", "trinidad and tobago", "barbados", "saint lucia",
    "sint maarten", "cayman islands", "turks and caicos islands", "antigua and barbuda", "grenada",
    "guadeloupe", "martinique", "bonaire",
  ]

  private static let latinAmericaAirports: Set<String> = [
    "PTY", "BOG", "MDE", "CLO", "CTG", "BAQ", "SJO", "LIR", "LIM", "CUZ", "UIO", "GYE", "SCL", "EZE", "AEP",
    "COR", "MDZ", "GRU", "GIG", "BSB", "CNF", "POA", "REC", "FOR", "SSA", "MAO", "MEX", "CUN", "GDL", "MTY",
    "SJD", "PVR", "GUA", "SAL", "TGU", "SAP", "RTB", "MGA", "BZE", "HAV", "SDQ", "PUJ", "STI", "MBJ", "KIN",
    "SJU", "CCS", "MVD", "ASU", "VVI", "LPB", "AUA", "CUR", "BON", "SXM", "POS", "BGI", "NAS", "GEO", "PBM",
    "SAO", "RIO", "BUE",
  ]

  static func servesLatinAmerica(_ place: Place) -> Bool {
    if let country = place.country?.lowercased(), latinAmericaCountries.contains(country) { return true }
    return latinAmericaAirports.contains(place.code.uppercased())
  }
}
