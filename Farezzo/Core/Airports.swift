import Foundation

/// Which airports a search covers. A city means all its airports; "nearby airports" adds the
/// alternatives people actually fly from (often with low-cost carriers and lower fares).
enum Airports {
  /// City code → its airports.
  static let metro: [String: [String]] = [
    "NYC": ["JFK", "EWR", "LGA"], "WAS": ["IAD", "DCA", "BWI"], "CHI": ["ORD", "MDW"],
    "LAX": ["LAX", "BUR", "LGB", "SNA", "ONT"], "SFO": ["SFO", "OAK", "SJC"], "MIA": ["MIA", "FLL", "PBI"],
    "DFW": ["DFW", "DAL"], "HOU": ["IAH", "HOU"], "ORL": ["MCO", "SFB"], "DTT": ["DTW"],
    "YTO": ["YYZ", "YTZ"], "YMQ": ["YUL"], "YVR": ["YVR"], "MEX": ["MEX", "NLU"],
    "SAO": ["GRU", "CGH", "VCP"], "RIO": ["GIG", "SDU"], "BUE": ["EZE", "AEP"],
    "LON": ["LHR", "LGW", "STN", "LTN", "LCY", "SEN"], "PAR": ["CDG", "ORY", "BVA"],
    "MIL": ["MXP", "LIN", "BGY"], "ROM": ["FCO", "CIA"], "BER": ["BER"], "STO": ["ARN", "BMA", "NYO"],
    "OSL": ["OSL", "TRF", "RYG"], "MOW": ["SVO", "DME", "VKO"], "IST": ["IST", "SAW"],
    "BRU": ["BRU", "CRL"], "FRA": ["FRA", "HHN"], "GLA": ["GLA", "PIK"], "BCN": ["BCN", "GRO", "REU"],
    "VCE": ["VCE", "TSF"], "BUH": ["OTP", "BBU"], "REK": ["KEF", "RKV"],
    "TYO": ["HND", "NRT"], "OSA": ["KIX", "ITM", "UKB"], "SEL": ["ICN", "GMP"], "BJS": ["PEK", "PKX"],
    "SHA": ["PVG", "SHA"], "BKK": ["BKK", "DMK"], "JKT": ["CGK", "HLP"], "KUL": ["KUL", "SZB"],
    "TPE": ["TPE", "TSA"], "DXB": ["DXB", "DWC"], "MEL": ["MEL", "AVV"],
  ]

  /// Airport or city → other airports within reasonable reach.
  static let nearby: [String: [String]] = [
    "NYC": ["HPN", "ISP", "SWF"], "JFK": ["EWR", "LGA"], "EWR": ["JFK", "LGA"], "LGA": ["JFK", "EWR"],
    "BOS": ["PVD", "MHT"], "WAS": ["RIC"], "PHL": ["ABE", "TTN"], "CHI": ["MKE"],
    "LAX": ["BUR", "LGB", "SNA", "ONT"], "SFO": ["OAK", "SJC", "SMF"], "SEA": ["PAE"],
    "MIA": ["FLL", "PBI"], "FLL": ["MIA", "PBI"], "ORL": ["TPA"], "MCO": ["SFB", "TPA"],
    "TPA": ["PIE", "SRQ"], "DFW": ["DAL"], "HOU": [], "SAN": ["TIJ"], "LAS": [], "PHX": ["AZA"],
    "LON": [], "LHR": ["LGW", "STN", "LTN", "LCY"], "MAN": ["LPL", "LBA"], "PAR": [],
    "CDG": ["ORY", "BVA"], "AMS": ["EIN", "RTM"], "BRU": ["CRL", "EIN"], "FRA": ["HHN"],
    "DUS": ["CGN", "DTM"], "MUC": ["MMQ"], "MIL": [], "ROM": [], "BCN": ["GRO", "REU"],
    "MAD": [], "LIS": [], "VIE": ["BTS"], "CPH": ["MMX"], "ZRH": ["BSL"], "GVA": [],
    "NCE": [], "VCE": ["TSF"], "DUB": [], "TYO": [], "HKG": ["SZX", "MFM"], "SIN": ["JHB"],
    "SYD": [], "MEL": ["AVV"],
  ]

  /// The airport codes a search for `place` covers.
  static func codes(for place: Place, nearby includeNearby: Bool) -> [String] {
    var codes: [String]
    if let airports = metro[place.code] {
      codes = airports
    } else if place.kind == .airport, includeNearby,
              let city = metro.first(where: { $0.value.contains(place.code) })?.value {
      codes = [place.code] + city.filter { $0 != place.code }
    } else {
      codes = [place.code]
    }
    if includeNearby {
      for code in [place.code] + codes {
        for extra in nearby[code] ?? [] where !codes.contains(extra) { codes.append(extra) }
      }
    }
    // Google Flights accepts a handful of airports per side.
    return Array(codes.prefix(7))
  }

  /// The airports the user literally asked for (anything else is a nearby alternative).
  static func primaryCodes(for place: Place) -> Set<String> {
    Set(codes(for: place, nearby: false) + [place.code])
  }

  /// A good code for providers that understand city codes (Duffel, Aviasales).
  static func cityOrAirportCode(for place: Place) -> String { place.code }

  /// Places shown before anything is typed.
  static let popular: [Place] = popularList.map {
    Place(code: $0.0, name: $0.1, cityName: $0.1, country: $0.2, kind: .city)
  }

  private static let popularList: [(String, String, String)] = [
    ("NYC", "New York", "United States"), ("LON", "London", "United Kingdom"), ("PAR", "Paris", "France"),
    ("TYO", "Tokyo", "Japan"), ("LAX", "Los Angeles", "United States"), ("ROM", "Rome", "Italy"),
    ("BCN", "Barcelona", "Spain"), ("DXB", "Dubai", "United Arab Emirates"), ("CUN", "Cancún", "Mexico"),
    ("LIS", "Lisbon", "Portugal"), ("BKK", "Bangkok", "Thailand"), ("SIN", "Singapore", "Singapore"),
    ("MIA", "Miami", "United States"), ("AMS", "Amsterdam", "Netherlands"), ("HNL", "Honolulu", "United States"),
    ("SEL", "Seoul", "South Korea"), ("CHI", "Chicago", "United States"), ("SFO", "San Francisco", "United States"),
    ("SYD", "Sydney", "Australia"), ("IST", "Istanbul", "Türkiye"), ("REK", "Reykjavík", "Iceland"),
    ("MEX", "Mexico City", "Mexico"), ("ATH", "Athens", "Greece"), ("YTO", "Toronto", "Canada"),
  ]
}
