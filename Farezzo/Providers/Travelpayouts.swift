import Foundation

/// Travelpayouts / Aviasales (travelpayouts.com). Its fare data is the lowest prices travelers
/// found in the last days across hundreds of agencies and low-cost carriers. That makes it
/// free and good for "which day is cheapest" calendars and for budget fares, but each price is
/// recent, not live, so the app marks them as such.
struct Travelpayouts {
  let token: String

  struct Fare {
    var origin: String
    var destination: String
    var departs: Date
    var returns: Date?
    var price: Double
    var airline: String
    var flightNumber: String
    var transfers: Int
    var returnTransfers: Int
    var minutesOut: Int?
    var minutesBack: Int?
    var link: URL?
  }

  /// Fares for a month ("2026-12") or a day ("2026-12-03"), cheapest first. `price` is per traveler.
  func fares(origin: String, destination: String, departure: String, returning: String?, oneWay: Bool,
             currency: String, directOnly: Bool = false) async throws -> [Fare] {
    var params: [(String, String)] = [
      ("origin", origin), ("destination", destination), ("departure_at", departure),
      ("one_way", oneWay ? "true" : "false"), ("direct", directOnly ? "true" : "false"),
      ("sorting", "price"), ("unique", "false"), ("limit", "1000"), ("page", "1"),
      ("currency", currency.lowercased()), ("token", token),
    ]
    if let returning { params.append(("return_at", returning)) }
    let (json, status) = try await HTTP.get(HTTP.url("https://api.travelpayouts.com/aviasales/v3/prices_for_dates", params))
    if json["success"].bool == false {
      throw ProviderError.message("Aviasales: \(json["error"].string ?? "request failed")")
    }
    guard (200..<300).contains(status) else { throw ProviderError.http(status, "Aviasales") }
    return json["data"].array.compactMap { item in
      guard let price = item["price"].double, let departs = Fmt.naive(item["departure_at"].string) else { return nil }
      let airline = item["airline"].string ?? ""
      return Fare(
        origin: item["origin_airport"].string ?? item["origin"].string ?? origin,
        destination: item["destination_airport"].string ?? item["destination"].string ?? destination,
        departs: departs,
        returns: Fmt.naive(item["return_at"].string),
        price: price,
        airline: airline,
        flightNumber: "\(airline) \(item["flight_number"].string ?? "")",
        transfers: item["transfers"].int ?? 0,
        returnTransfers: item["return_transfers"].int ?? 0,
        minutesOut: item["duration_to"].int ?? item["duration"].int,
        minutesBack: item["duration_back"].int,
        link: item["link"].string.flatMap { URL(string: "https://www.aviasales.com" + $0) })
    }
  }

  /// The cheapest recent fare for each departure day of the month, preferring trips of the
  /// requested length (±1 day) when there are any.
  func calendar(origin: String, destination: String, month: Date, tripLength: Int?, currency: String) async throws -> [Date: Double] {
    let fares = try await fares(origin: origin, destination: destination, departure: Fmt.ym.string(from: month),
                                returning: nil, oneWay: tripLength == nil, currency: currency)
    var all: [Date: Double] = [:]
    var matching: [Date: Double] = [:]
    for fare in fares {
      guard let day = Fmt.day(ofNaive: fare.departs) else { continue }
      all[day] = min(all[day] ?? .infinity, fare.price)
      if let tripLength, let returns = fare.returns {
        let length = Fmt.utcCalendar.dateComponents([.day], from: fare.departs, to: returns).day ?? 0
        if abs(length - tripLength) <= 1 { matching[day] = min(matching[day] ?? .infinity, fare.price) }
      }
    }
    return matching.count >= max(3, all.count / 3) ? matching : all
  }

  /// Recent fares on the exact dates, as offers (total for all travelers).
  func offers(origin: String, destination: String, depart: Date, ret: Date?, travelers: Int, currency: String) async throws -> [FlightOffer] {
    let fares = try await fares(origin: origin, destination: destination, departure: Fmt.ymd.string(from: depart),
                                returning: ret.map { Fmt.ymd.string(from: $0) }, oneWay: ret == nil, currency: currency)
    return fares.prefix(25).map { fare in
      let out = Self.leg(from: fare.origin, to: fare.destination, departs: fare.departs, minutes: fare.minutesOut,
                         stops: fare.transfers, airline: fare.airline, flightNumber: fare.flightNumber)
      let back = fare.returns.map {
        Self.leg(from: fare.destination, to: fare.origin, departs: $0, minutes: fare.minutesBack,
                 stops: fare.returnTransfers, airline: fare.airline, flightNumber: fare.airline)
      }
      var offer = FlightOffer(
        id: "",
        price: fare.price * Double(max(1, travelers)),
        currency: currency.uppercased(),
        outbound: out,
        inbound: back,
        isRoundTrip: ret != nil,
        departDate: depart,
        returnDate: ret,
        providers: [.aviasales],
        tags: [.cached])
      offer.notes.append("A fare travelers found recently on Aviasales. It's usually still available, but check the live price before you book.")
      if let link = fare.link { offer.bookings = [BookingLink(label: "Aviasales", url: link)] }
      offer.id = "AS|" + out.key + "|" + (back?.key ?? "-") + "|\(Int(fare.price))"
      return offer
    }
  }

  /// The fare data only gives departure time, duration and number of stops: one summary segment.
  private static func leg(from: String, to: String, departs: Date, minutes: Int?, stops: Int, airline: String, flightNumber: String) -> FlightLeg {
    let duration = minutes ?? 0
    let segment = FlightSegment(fromCode: from, fromName: from, toCode: to, toName: to, departs: departs,
                                arrives: departs.addingTimeInterval(TimeInterval(duration * 60)),
                                airline: airline, flightNumber: flightNumber, logo: airlineLogo(airline),
                                durationMinutes: duration)
    return FlightLeg(segments: [segment], layovers: [], durationMinutes: duration, unlistedStops: max(0, stops))
  }

  static func airlineLogo(_ code: String) -> URL? {
    code.isEmpty ? nil : URL(string: "https://pics.avs.io/120/120/\(code).png")
  }

  /// Airport and city search as the user types (no key needed).
  static func autocomplete(_ term: String) async throws -> [Place] {
    let url = HTTP.url("https://autocomplete.travelpayouts.com/places2", [
      ("term", term), ("locale", "en"), ("types[]", "city"), ("types[]", "airport"),
    ])
    let (json, _) = try await HTTP.get(url)
    return json.array.compactMap { item in
      guard let code = item["code"].string, let name = item["name"].string else { return nil }
      let kind: Place.Kind = item["type"].string == "airport" ? .airport : .city
      return Place(code: code, name: name, cityName: kind == .airport ? item["city_name"].string : name,
                   country: item["country_name"].string, kind: kind,
                   latitude: item["coordinates"]["lat"].double, longitude: item["coordinates"]["lon"].double)
    }
  }
}
