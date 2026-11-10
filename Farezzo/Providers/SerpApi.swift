import Foundation

/// Google Flights and Google Hotels through SerpApi (serpapi.com). Google's results already
/// combine almost every airline and online travel agency (and, for hotels, Booking.com, Expedia,
/// Hotels.com, Agoda, Trip.com, the hotel's own site and more), so this is the widest source.
/// Each call here is one search on the user's SerpApi plan.
struct SerpApi {
  let key: String

  struct FlightPage {
    var offers: [FlightOffer] = []
    var insights: PriceInsights?
    var googleURL: URL?
  }

  struct HotelPage {
    var hotels: [HotelOffer] = []
    var googleURL: URL?
  }

  // MARK: - Requests

  func search(_ params: [String: String]) async throws -> JSONValue {
    let items = params.sorted { $0.key < $1.key }.map { ($0.key, $0.value) } + [("api_key", key)]
    let (json, status) = try await HTTP.get(HTTP.url("https://serpapi.com/search.json", items))
    if let error = json["error"].string {
      // "hasn't returned any results" is an empty result, not a failure.
      if error.localizedCaseInsensitiveContains("returned any results") { return json }
      throw ProviderError.message("SerpApi: \(error)")
    }
    guard (200..<300).contains(status) else { throw ProviderError.http(status, "SerpApi") }
    return json
  }

  /// Searches left on the plan.
  func account() async throws -> (left: Int?, plan: String?) {
    let (json, _) = try await HTTP.get(HTTP.url("https://serpapi.com/account.json", [("api_key", key)]))
    if let error = json["error"].string { throw ProviderError.message(error) }
    return (json["total_searches_left"].int ?? json["plan_searches_left"].int, json["plan_name"].string)
  }

  // MARK: - Flights

  struct FlightRequest {
    var origins: [String]
    var destinations: [String]
    var depart: Date
    var ret: Date?
    var adults: Int
    var children: Int
    var cabin: Cabin
    var maxStops: Int?
    var currency: String
    var region: String
    var deep: Bool
  }

  static func flightParams(_ request: FlightRequest) -> [String: String] {
    var params: [String: String] = [
      "engine": "google_flights",
      "departure_id": request.origins.joined(separator: ","),
      "arrival_id": request.destinations.joined(separator: ","),
      "outbound_date": Fmt.ymd.string(from: request.depart),
      "type": request.ret == nil ? "2" : "1",
      "adults": "\(request.adults)",
      "travel_class": "\(request.cabin.rawValue)",
      "currency": request.currency,
      "hl": "en",
      "gl": request.region,
      "sort_by": "2",  // price
    ]
    if let ret = request.ret { params["return_date"] = Fmt.ymd.string(from: ret) }
    if request.children > 0 { params["children"] = "\(request.children)" }
    if let maxStops = request.maxStops { params["stops"] = "\(min(3, maxStops + 1))" }
    if request.deep { params["deep_search"] = "true" }
    return params
  }

  func flights(_ request: FlightRequest) async throws -> FlightPage {
    let params = Self.flightParams(request)
    let json = try await search(params)
    return Self.parseFlightPage(json, params: params, currency: request.currency, depart: request.depart, ret: request.ret)
  }

  /// A round trip's return choices for one outbound option (each one priced as the whole trip).
  func returnFlights(for offer: FlightOffer) async throws -> [FlightOffer] {
    guard var params = offer.serpParams, let token = offer.serpReturnToken else { return [] }
    params["departure_token"] = token
    let json = try await search(params)
    let page = Self.parseFlightPage(json, params: params, currency: offer.currency, depart: offer.departDate,
                                    ret: offer.returnDate, outbound: offer)
    return page.offers
  }

  /// Where the chosen flights can be booked, cheapest first.
  func bookingOptions(params base: [String: String], token: String) async throws -> [BookingLink] {
    var params = base
    params.removeValue(forKey: "departure_token")
    params["booking_token"] = token
    let json = try await search(params)
    return Self.parseBookingOptions(json)
  }

  static func parseBookingOptions(_ json: JSONValue) -> [BookingLink] {
    var links: [BookingLink] = []
    for option in json["booking_options"].array {
      let choice = option["together"].isNull ? option["departing"] : option["together"]
      guard let url = choice["booking_request"]["url"].url else { continue }
      links.append(BookingLink(
        label: choice["book_with"].string ?? "Book",
        url: url,
        postBody: choice["booking_request"]["post_data"].string,
        price: choice["price"].double))
    }
    return links.sorted { ($0.price ?? .infinity) < ($1.price ?? .infinity) }
  }

  static func parseFlightPage(_ json: JSONValue, params: [String: String], currency: String, depart: Date, ret: Date?,
                              outbound: FlightOffer? = nil) -> FlightPage {
    var page = FlightPage()
    page.googleURL = json["search_metadata"]["google_flights_url"].url
    let insights = json["price_insights"]
    if !insights.isNull {
      let range = insights["typical_price_range"]
      page.insights = PriceInsights(
        lowest: insights["lowest_price"].double,
        level: insights["price_level"].string,
        typicalLow: range[0].double,
        typicalHigh: range[1].double,
        history: insights["price_history"].array.compactMap { point in
          guard let seconds = point[0].double, let price = point[1].double else { return nil }
          return PricePoint(date: Date(timeIntervalSince1970: seconds), price: price)
        })
    }
    let items = json["best_flights"].array + json["other_flights"].array
    for item in items {
      guard let price = item["price"].double, let leg = parseLeg(item) else { continue }
      var offer: FlightOffer
      if let outbound {
        offer = outbound
        offer.inbound = leg
        offer.price = price
        offer.serpReturnToken = nil
        offer.serpBookingToken = item["booking_token"].string
        offer.id = offer.dedupeKey
      } else {
        offer = FlightOffer(
          id: "",
          price: price,
          currency: currency,
          outbound: leg,
          inbound: nil,
          isRoundTrip: ret != nil,
          departDate: depart,
          returnDate: ret,
          providers: [.googleFlights],
          serpParams: params,
          serpReturnToken: ret != nil ? item["departure_token"].string : nil,
          serpBookingToken: item["booking_token"].string)
        offer.id = offer.dedupeKey
      }
      if let url = page.googleURL {
        offer.bookings = [BookingLink(label: "Google Flights", url: url)]
      }
      page.offers.append(offer)
    }
    return page
  }

  static func parseLeg(_ item: JSONValue) -> FlightLeg? {
    let segments = item["flights"].array.compactMap(parseSegment)
    guard !segments.isEmpty else { return nil }
    let layovers = item["layovers"].array.map {
      Layover(code: $0["id"].string ?? "", name: $0["name"].string ?? "",
              minutes: $0["duration"].int ?? 0, overnight: $0["overnight"].bool ?? false)
    }
    let computed = segments.reduce(0) { $0 + $1.durationMinutes } + layovers.reduce(0) { $0 + $1.minutes }
    return FlightLeg(segments: segments, layovers: layovers, durationMinutes: item["total_duration"].int ?? computed)
  }

  static func parseSegment(_ flight: JSONValue) -> FlightSegment? {
    let from = flight["departure_airport"]
    let to = flight["arrival_airport"]
    guard let departs = Fmt.naive(from["time"].string), let arrives = Fmt.naive(to["time"].string) else { return nil }
    return FlightSegment(
      fromCode: from["id"].string ?? "",
      fromName: from["name"].string ?? "",
      toCode: to["id"].string ?? "",
      toName: to["name"].string ?? "",
      departs: departs,
      arrives: arrives,
      airline: flight["airline"].string ?? "",
      flightNumber: flight["flight_number"].string ?? "",
      logo: flight["airline_logo"].url,
      durationMinutes: flight["duration"].int ?? Int(arrives.timeIntervalSince(departs) / 60),
      aircraft: flight["airplane"].string,
      overnight: flight["overnight"].bool ?? false)
  }

  // MARK: - Hotels

  enum HotelSort: String { case relevance = "", lowestPrice = "3", highestRating = "8", mostReviewed = "13" }

  static func hotelParams(_ query: SearchQuery, sort: HotelSort, rentals: Bool) -> [String: String] {
    var params: [String: String] = [
      "engine": "google_hotels",
      "q": query.destination?.hotelQuery ?? "",
      "check_in_date": Fmt.ymd.string(from: query.departDate),
      "check_out_date": Fmt.ymd.string(from: query.checkOut),
      "adults": "\(max(1, query.adults))",
      "currency": query.currency,
      "gl": query.region,
      "hl": "en",
    ]
    if query.children > 0 {
      params["children"] = "\(query.children)"
      params["children_ages"] = Array(repeating: "10", count: query.children).joined(separator: ",")
    }
    if !sort.rawValue.isEmpty { params["sort_by"] = sort.rawValue }
    if rentals {
      params["vacation_rentals"] = "true"
    } else if query.minStars >= 2 {
      params["hotel_class"] = (query.minStars...5).map(String.init).joined(separator: ",")
    }
    if query.minRating >= 4.5 { params["rating"] = "9" }
    else if query.minRating >= 4.0 { params["rating"] = "8" }
    else if query.minRating >= 3.5 { params["rating"] = "7" }
    if query.freeCancellation { params["free_cancellation"] = "true" }
    return params
  }

  func hotels(_ query: SearchQuery, sort: HotelSort, rentals: Bool) async throws -> HotelPage {
    let params = Self.hotelParams(query, sort: sort, rentals: rentals)
    let json = try await search(params)
    return Self.parseHotelPage(json, params: params, query: query, rentals: rentals)
  }

  /// Every site's price for one property (the list Google shows on the hotel's page).
  func hotelDetails(_ hotel: HotelOffer) async throws -> HotelOffer {
    guard var params = hotel.serpParams, let token = hotel.propertyToken else { return hotel }
    params["property_token"] = token
    params.removeValue(forKey: "sort_by")
    let json = try await search(params)
    var updated = hotel
    let nights = max(1, hotel.nights)
    var sources: [String: HotelSourcePrice] = Dictionary(uniqueKeysWithValues: hotel.sources.map { ($0.source, $0) })
    for item in json["featured_prices"].array + json["prices"].array {
      guard let source = Self.parseSource(item, nights: nights) else { continue }
      if let existing = sources[source.source], (existing.total ?? .infinity) <= (source.total ?? .infinity),
         existing.url != nil { continue }
      sources[source.source] = source
    }
    updated.sources = sources.values.sorted { ($0.total ?? .infinity) < ($1.total ?? .infinity) }
    if let cheapest = updated.cheapestSource?.total, cheapest < updated.total {
      updated.total = cheapest
      updated.nightly = cheapest / Double(nights)
    }
    if updated.website == nil { updated.website = json["link"].url }
    if updated.images.isEmpty {
      updated.images = json["images"].array.compactMap { $0["original_image"].url ?? $0["thumbnail"].url }
    }
    return updated
  }

  static func parseSource(_ item: JSONValue, nights: Int) -> HotelSourcePrice? {
    guard let source = item["source"].string else { return nil }
    let nightly = item["rate_per_night"]["extracted_lowest"].double
    let total = item["total_rate"]["extracted_lowest"].double ?? nightly.map { $0 * Double(nights) }
    let free = item["rooms"].array.contains { room in
      (room["name"].string ?? "").localizedCaseInsensitiveContains("free cancellation")
    } || (item["free_cancellation"].bool ?? false)
    return HotelSourcePrice(source: source, total: total, nightly: nightly, url: item["link"].url,
                            logo: item["logo"].url, official: item["official"].bool ?? false,
                            freeCancellation: free)
  }

  static func parseHotelPage(_ json: JSONValue, params: [String: String], query: SearchQuery, rentals: Bool) -> HotelPage {
    var page = HotelPage()
    page.googleURL = json["search_metadata"]["google_hotels_url"].url
    let nights = query.nights
    for property in json["properties"].array {
      guard let name = property["name"].string else { continue }
      let nightly = property["rate_per_night"]["extracted_lowest"].double
      guard let total = property["total_rate"]["extracted_lowest"].double ?? nightly.map({ $0 * Double(nights) }) else { continue }
      let token = property["property_token"].string
      var hotel = HotelOffer(
        id: token ?? name.lowercased(),
        name: name,
        kind: property["type"].string,
        stars: property["extracted_hotel_class"].int,
        rating: property["overall_rating"].double,
        reviews: property["reviews"].int,
        total: total,
        nightly: nightly ?? total / Double(nights),
        nightlyBeforeTaxes: property["rate_per_night"]["extracted_before_taxes_fees"].double,
        currency: query.currency,
        nights: nights,
        checkIn: query.departDate,
        checkOut: query.checkOut,
        images: property["images"].array.compactMap { $0["original_image"].url ?? $0["thumbnail"].url },
        amenities: property["amenities"].array.compactMap(\.string),
        summary: property["description"].string,
        latitude: property["gps_coordinates"]["latitude"].double,
        longitude: property["gps_coordinates"]["longitude"].double,
        website: property["link"].url,
        sources: property["prices"].array.compactMap { parseSource($0, nights: nights) },
        dealText: property["deal_description"].string ?? property["deal"].string,
        propertyToken: token,
        serpParams: params,
        googleURL: page.googleURL)
      if rentals || (hotel.kind ?? "").localizedCaseInsensitiveContains("rental") { hotel.tags.insert(.vacationRental) }
      if hotel.dealText != nil { hotel.tags.insert(.deal) }
      if property["free_cancellation"].bool == true || hotel.sources.contains(where: \.freeCancellation) || query.freeCancellation {
        hotel.tags.insert(.freeCancellation)
      }
      page.hotels.append(hotel)
    }
    // Sponsored listings carry real prices from other booking sites: fold them in.
    for ad in json["ads"].array {
      guard let name = ad["name"].string, let nightlyPrice = ad["extracted_price"].double else { continue }
      let source = HotelSourcePrice(source: ad["source"].string ?? "Ad", total: nightlyPrice * Double(nights),
                                    nightly: nightlyPrice, url: ad["link"].url, logo: ad["source_icon"].url)
      let token = ad["property_token"].string
      if let index = page.hotels.firstIndex(where: { ($0.propertyToken != nil && $0.propertyToken == token) || $0.name.lowercased() == name.lowercased() }) {
        if !page.hotels[index].sources.contains(where: { $0.source == source.source }) {
          page.hotels[index].sources.append(source)
        }
        if let total = source.total, total < page.hotels[index].total {
          page.hotels[index].total = total
          page.hotels[index].nightly = nightlyPrice
        }
      }
    }
    return page
  }

  // MARK: - Links

  /// Opens the same search on Google Flights (works for any flight, whichever provider found it).
  static func googleFlightsURL(from: String, to: String, depart: Date, ret: Date?) -> URL {
    var text = "Flights from \(from) to \(to) on \(Fmt.ymd.string(from: depart))"
    if let ret { text += " through \(Fmt.ymd.string(from: ret))" } else { text += " one way" }
    return HTTP.url("https://www.google.com/travel/flights", [("q", text)])
  }
}
