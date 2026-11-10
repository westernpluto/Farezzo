import Foundation

enum TripMode: String, CaseIterable, Codable, Identifiable, Hashable {
  case flights, package, hotels
  var id: String { rawValue }
  var title: String {
    switch self {
    case .flights: return "Flights"
    case .package: return "Flight + Hotel"
    case .hotels: return "Hotels"
    }
  }
  var icon: String {
    switch self {
    case .flights: return "airplane"
    case .package: return "suitcase.rolling"
    case .hotels: return "bed.double"
    }
  }
  var needsFlights: Bool { self != .hotels }
  var needsHotels: Bool { self != .flights }
}

enum Cabin: Int, CaseIterable, Codable, Identifiable, Hashable {
  case economy = 1, premiumEconomy, business, first
  var id: Int { rawValue }
  var title: String {
    switch self {
    case .economy: return "Economy"
    case .premiumEconomy: return "Premium economy"
    case .business: return "Business"
    case .first: return "First"
    }
  }
  var duffel: String {
    switch self {
    case .economy: return "economy"
    case .premiumEconomy: return "premium_economy"
    case .business: return "business"
    case .first: return "first"
    }
  }
}

/// A city (all of its airports) or one airport.
struct Place: Codable, Hashable, Identifiable {
  enum Kind: String, Codable { case city, airport }
  var code: String
  var name: String
  var cityName: String?
  var country: String?
  var kind: Kind
  var latitude: Double?
  var longitude: Double?

  var id: String { "\(kind.rawValue)-\(code)" }

  var title: String { kind == .city ? name : "\(name)" }
  var subtitle: String {
    var parts: [String] = []
    if kind == .airport, let cityName, cityName != name { parts.append(cityName) }
    if let country { parts.append(country) }
    parts.append(kind == .city ? "\(code) · all airports" : code)
    return parts.joined(separator: " · ")
  }
  /// What to look hotels up by.
  var hotelQuery: String {
    let city = kind == .airport ? (cityName ?? name) : name
    return [city, country].compactMap { $0 }.joined(separator: ", ")
  }
  var shortLabel: String { kind == .city ? "\(name) (\(code))" : "\(cityName ?? name) (\(code))" }
}

struct SearchQuery: Codable, Hashable {
  var mode: TripMode = .flights
  var origin: Place?
  var destination: Place?
  var departDate: Date = Fmt.addDays(21, to: Date())
  var returnDate: Date? = Fmt.addDays(28, to: Date())
  var adults = 1
  var children = 0
  var cabin: Cabin = .economy
  /// nil: any number of stops.
  var maxStops: Int?

  // Deal hunting
  var includeNearbyAirports = true
  var flexDays = 3
  var trySplitTickets = true
  var checkOtherMarkets = true
  var compareAllHotelSites = true

  // Hotels
  var minStars = 0
  var minRating = 0.0
  var freeCancellation = false
  var includeVacationRentals = true

  var currency = Locale.current.currency?.identifier ?? "USD"
  var region = (Locale.current.region?.identifier ?? "US").lowercased()

  var isRoundTrip: Bool { returnDate != nil }
  var travelers: Int { adults + children }
  var nights: Int {
    guard let returnDate else { return 1 }
    return max(1, Fmt.days(from: departDate, to: returnDate))
  }
  /// Stays need two dates, so hotels and packages are always round trips.
  var checkOut: Date { returnDate ?? Fmt.addDays(1, to: departDate) }

  var summary: String {
    let route: String
    switch mode {
    case .hotels: route = destination?.hotelQuery ?? "Hotels"
    default: route = "\(origin?.code ?? "?") → \(destination?.code ?? "?")"
    }
    var dates = Fmt.dayShort.string(from: departDate)
    if let returnDate { dates += " – " + Fmt.dayShort.string(from: returnDate) }
    return "\(route) · \(dates)"
  }

  var problems: [String] {
    var issues: [String] = []
    if mode.needsFlights && origin == nil { issues.append("Choose where you're leaving from.") }
    if destination == nil { issues.append("Choose a destination.") }
    if mode.needsHotels && returnDate == nil { issues.append("Stays need a check-out date.") }
    if let returnDate, returnDate <= departDate { issues.append("The return date must be after departure.") }
    if Calendar.current.startOfDay(for: departDate) < Calendar.current.startOfDay(for: Date()) {
      issues.append("The departure date is in the past.")
    }
    if let origin, let destination, mode.needsFlights, origin.code == destination.code {
      issues.append("Origin and destination are the same.")
    }
    return issues
  }
}

enum Provider: String, Codable, Hashable, CaseIterable {
  case googleFlights = "Google Flights"
  case duffel = "Duffel"
  case aviasales = "Aviasales"
  case googleHotels = "Google Hotels"
  case booking = "Booking.com"
}

enum DealTag: String, Codable, Hashable, CaseIterable {
  case cheapest, bestValue, fastest, nonstop, splitTicket, nearbyAirport, flexibleDate, otherMarket
  case cached, airlineDirect, freeCancellation, topRated, deal, vacationRental

  var title: String {
    switch self {
    case .cheapest: return "Cheapest"
    case .bestValue: return "Best value"
    case .fastest: return "Fastest"
    case .nonstop: return "Nonstop"
    case .splitTicket: return "Split ticket"
    case .nearbyAirport: return "Nearby airport"
    case .flexibleDate: return "Other date"
    case .otherMarket: return "Other region"
    case .cached: return "Recent fare"
    case .airlineDirect: return "Airline direct"
    case .freeCancellation: return "Free cancellation"
    case .topRated: return "Top rated"
    case .deal: return "Deal"
    case .vacationRental: return "Rental"
    }
  }

  var icon: String {
    switch self {
    case .cheapest: return "dollarsign.circle.fill"
    case .bestValue: return "star.circle.fill"
    case .fastest: return "bolt.fill"
    case .nonstop: return "arrow.right"
    case .splitTicket: return "ticket"
    case .nearbyAirport: return "mappin.and.ellipse"
    case .flexibleDate: return "calendar"
    case .otherMarket: return "globe"
    case .cached: return "clock.arrow.circlepath"
    case .airlineDirect: return "airplane.circle"
    case .freeCancellation: return "checkmark.shield"
    case .topRated: return "hand.thumbsup.fill"
    case .deal: return "tag.fill"
    case .vacationRental: return "house"
    }
  }
}

struct FlightSegment: Codable, Hashable {
  var fromCode: String
  var fromName: String
  var toCode: String
  var toName: String
  var departs: Date
  var arrives: Date
  var airline: String
  var flightNumber: String
  var logo: URL?
  var durationMinutes: Int
  var aircraft: String?
  var overnight = false
}

struct Layover: Codable, Hashable {
  var code: String
  var name: String
  var minutes: Int
  var overnight = false
}

struct FlightLeg: Codable, Hashable {
  var segments: [FlightSegment]
  var layovers: [Layover]
  var durationMinutes: Int
  /// Stops a provider counted without naming the airports (cached fares).
  var unlistedStops = 0

  var stops: Int { max(0, segments.count - 1) + unlistedStops }
  var departs: Date? { segments.first?.departs }
  var arrives: Date? { segments.last?.arrives }
  var fromCode: String { segments.first?.fromCode ?? "" }
  var toCode: String { segments.last?.toCode ?? "" }
  var airlines: [String] {
    var seen: [String] = []
    for segment in segments where !seen.contains(segment.airline) { seen.append(segment.airline) }
    return seen
  }
  var logo: URL? { segments.first?.logo }
  var stopsText: String {
    switch stops {
    case 0: return "Nonstop"
    case 1: return "1 stop" + (layovers.first.flatMap { $0.code.isEmpty ? nil : " · \($0.code)" } ?? "")
    default: return "\(stops) stops"
    }
  }
  /// Identifies the same flights found by different providers.
  var key: String {
    segments.map { "\($0.flightNumber.replacingOccurrences(of: " ", with: ""))@\(Int($0.departs.timeIntervalSince1970))" }
      .joined(separator: ">")
  }

  /// Builds layovers from the gaps between segments (for providers that don't list them).
  static func make(segments: [FlightSegment], durationMinutes: Int? = nil) -> FlightLeg {
    var layovers: [Layover] = []
    for (a, b) in zip(segments, segments.dropFirst()) {
      let minutes = Int(b.departs.timeIntervalSince(a.arrives) / 60)
      let overnight = !Fmt.utcCalendar.isDate(a.arrives, inSameDayAs: b.departs)
      layovers.append(Layover(code: a.toCode, name: a.toName, minutes: max(0, minutes), overnight: overnight))
    }
    let total = durationMinutes
      ?? (segments.reduce(0) { $0 + $1.durationMinutes } + layovers.reduce(0) { $0 + $1.minutes })
    return FlightLeg(segments: segments, layovers: layovers, durationMinutes: total)
  }
}

struct BookingLink: Codable, Hashable, Identifiable {
  var label: String
  var url: URL
  /// Some booking sites must be opened with a form POST (Google Flights' booking redirects).
  var postBody: String?
  var price: Double?
  /// Google Flights: text that identifies the chosen flight in the results list ("at 9:26 AM
  /// on", the airline), so the page can scroll to it, mark it and open it.
  var highlight: [String]? = nil
  var id: String { label + url.absoluteString + (postBody ?? "") }

  var isGoogleFlights: Bool {
    (url.host?.contains("google.") ?? false) && url.path.contains("/travel/flights")
  }

  private static let clock: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")!
    formatter.dateFormat = "h:mm a"
    return formatter
  }()

  /// How Google Flights describes this leg's times and airline in its results list.
  static func highlightHints(for leg: FlightLeg) -> [String] {
    var hints: [String] = []
    if let departs = leg.departs { hints.append("at \(clock.string(from: departs)) on") }
    if let arrives = leg.arrives { hints.append("at \(clock.string(from: arrives)) on") }
    let airline = (leg.segments.first?.airline ?? "")
      .components(separatedBy: ",").first?
      .components(separatedBy: " and ").first?
      .trimmingCharacters(in: .whitespaces) ?? ""
    if !airline.isEmpty && airline != "Airline" { hints.append("with \(airline)") }
    return hints
  }
}

struct FlightOffer: Codable, Hashable, Identifiable {
  var id: String
  /// The whole trip for every traveler, in `currency`.
  var price: Double
  var currency: String
  var outbound: FlightLeg
  /// nil for one-way trips, or for a Google Flights round trip until the return is chosen.
  var inbound: FlightLeg?
  var isRoundTrip: Bool
  var departDate: Date
  var returnDate: Date?
  var providers: [Provider]
  var bookings: [BookingLink] = []
  var tags: Set<DealTag> = []
  var notes: [String] = []
  /// Google Flights (SerpApi) continuation: the search's parameters, plus the token for the
  /// return flights (round trips) or the booking options.
  var serpParams: [String: String]?
  var serpReturnToken: String?
  var serpBookingToken: String?
  /// A split ticket's separate one-way tickets.
  var parts: [FlightOffer] = []

  var totalMinutes: Int { outbound.durationMinutes + (inbound?.durationMinutes ?? 0) }
  var maxStops: Int { max(outbound.stops, inbound?.stops ?? 0) }
  var dedupeKey: String {
    (isRoundTrip ? "RT|" : "OW|") + outbound.key + "|" + (inbound?.key ?? (serpReturnToken == nil ? "-" : "pending"))
  }
}

struct PriceInsights: Codable, Hashable {
  var lowest: Double?
  /// "low", "typical" or "high".
  var level: String?
  var typicalLow: Double?
  var typicalHigh: Double?
  var history: [PricePoint] = []
}

struct PricePoint: Codable, Hashable, Identifiable {
  var date: Date
  var price: Double
  var id: Date { date }
}

struct HotelSourcePrice: Codable, Hashable, Identifiable {
  var source: String
  var total: Double?
  var nightly: Double?
  var url: URL?
  var logo: URL?
  var official = false
  var freeCancellation = false
  var id: String { source }
}

struct HotelOffer: Codable, Hashable, Identifiable {
  var id: String
  var name: String
  var kind: String?
  var stars: Int?
  var rating: Double?
  var reviews: Int?
  /// The whole stay (every night, taxes and fees where the source gives them), in `currency`.
  var total: Double
  var nightly: Double?
  var nightlyBeforeTaxes: Double?
  var currency: String
  var nights: Int
  var checkIn: Date
  var checkOut: Date
  var images: [URL] = []
  var amenities: [String] = []
  var summary: String?
  var latitude: Double?
  var longitude: Double?
  var website: URL?
  var sources: [HotelSourcePrice] = []
  var dealText: String?
  var propertyToken: String?
  var serpParams: [String: String]?
  var googleURL: URL?
  var tags: Set<DealTag> = []

  var cheapestSource: HotelSourcePrice? {
    sources.filter { $0.total != nil }.min { ($0.total ?? .infinity) < ($1.total ?? .infinity) }
  }
  /// Lower is better: price weighed against how well guests rate it.
  var valueScore: Double {
    let ratingFactor = rating.map { max(0.7, min(1.6, 1 + (4.4 - $0) * 0.18)) } ?? 1.25
    let starFactor = stars.map { max(0.85, min(1.15, 1 + Double(3 - $0) * 0.04)) } ?? 1.05
    return total * ratingFactor * starFactor
  }
}

struct PackageDeal: Codable, Hashable, Identifiable {
  var flight: FlightOffer
  var hotel: HotelOffer
  var currency: String
  var tags: Set<DealTag> = []
  var id: String { flight.id + "+" + hotel.id }
  var total: Double { flight.price + hotel.total }
}
