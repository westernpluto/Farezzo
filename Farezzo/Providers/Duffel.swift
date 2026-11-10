import Foundation

/// Duffel (duffel.com): live fares straight from airlines' own systems (NDC), including fares and
/// carriers that don't always reach the travel agencies. Searching is free.
struct Duffel {
  let token: String

  struct Request {
    var origin: String
    var destination: String
    var depart: Date
    var ret: Date?
    var adults: Int
    var children: Int
    var cabin: Cabin
    var maxStops: Int?
  }

  func flights(_ request: Request) async throws -> [FlightOffer] {
    var slices: [[String: Any]] = [[
      "origin": request.origin, "destination": request.destination,
      "departure_date": Fmt.ymd.string(from: request.depart),
    ]]
    if let ret = request.ret {
      slices.append(["origin": request.destination, "destination": request.origin,
                     "departure_date": Fmt.ymd.string(from: ret)])
    }
    var passengers: [[String: Any]] = Array(repeating: ["type": "adult"], count: max(1, request.adults))
    passengers += Array(repeating: ["age": 10], count: request.children)
    var data: [String: Any] = ["slices": slices, "passengers": passengers, "cabin_class": request.cabin.duffel]
    if let maxStops = request.maxStops { data["max_connections"] = min(2, maxStops) }

    let url = HTTP.url("https://api.duffel.com/air/offer_requests",
                       [("return_offers", "true"), ("supplier_timeout", "25000")])
    let (json, status) = try await HTTP.postJSON(url, body: ["data": data], headers: [
      "Authorization": "Bearer \(token)",
      "Duffel-Version": "v2",
    ])
    if let message = json["errors"][0]["message"].string { throw ProviderError.message("Duffel: \(message)") }
    guard (200..<300).contains(status) else { throw ProviderError.http(status, "Duffel") }

    let offers = json["data"]["offers"].array.compactMap { Self.parseOffer($0, request: request) }
    return Array(offers.sorted { $0.price < $1.price }.prefix(60))
  }

  static func parseOffer(_ offer: JSONValue, request: Request) -> FlightOffer? {
    guard let price = offer["total_amount"].double, let currency = offer["total_currency"].string else { return nil }
    let legs = offer["slices"].array.compactMap(parseSlice)
    guard let outbound = legs.first else { return nil }
    let owner = offer["owner"]["name"].string ?? "the airline"
    var result = FlightOffer(
      id: "",
      price: price,
      currency: currency,
      outbound: outbound,
      inbound: legs.count > 1 ? legs[1] : nil,
      isRoundTrip: request.ret != nil,
      departDate: request.depart,
      returnDate: request.ret,
      providers: [.duffel],
      tags: [.airlineDirect])
    result.notes.append("Fare from \(owner)'s own system. Book it on \(owner)'s website or app.")
    result.bookings = [BookingLink(
      label: "Find on Google Flights",
      url: SerpApi.googleFlightsURL(from: request.origin, to: request.destination, depart: request.depart, ret: request.ret))]
    result.id = result.dedupeKey
    return result
  }

  static func parseSlice(_ slice: JSONValue) -> FlightLeg? {
    let segments: [FlightSegment] = slice["segments"].array.compactMap { segment in
      guard let departs = Fmt.naive(segment["departing_at"].string),
            let arrives = Fmt.naive(segment["arriving_at"].string) else { return nil }
      let carrier = segment["marketing_carrier"]
      let code = carrier["iata_code"].string ?? ""
      return FlightSegment(
        fromCode: segment["origin"]["iata_code"].string ?? "",
        fromName: segment["origin"]["name"].string ?? "",
        toCode: segment["destination"]["iata_code"].string ?? "",
        toName: segment["destination"]["name"].string ?? "",
        departs: departs,
        arrives: arrives,
        airline: carrier["name"].string ?? code,
        flightNumber: "\(code) \(segment["marketing_carrier_flight_number"].string ?? "")",
        logo: carrier["logo_symbol_url"].url,
        durationMinutes: Fmt.isoDurationMinutes(segment["duration"].string) ?? Int(arrives.timeIntervalSince(departs) / 60),
        aircraft: segment["aircraft"]["name"].string)
    }
    guard !segments.isEmpty else { return nil }
    return FlightLeg.make(segments: segments, durationMinutes: Fmt.isoDurationMinutes(slice["duration"].string))
  }
}
