import Foundation

/// Finds the lowest prices for a search by asking every configured source in parallel, then
/// widening the search where fares usually hide:
///  • every airport in the city, plus nearby alternatives
///  • other departure dates around the chosen ones (picked with the free fare calendar)
///  • two one-way tickets instead of a round trip (often on different airlines)
///  • the same search as seen from other countries' Google Flights
///  • for hotels, every booking site's price for the best candidates, and vacation rentals
/// Results from all sources are converted to one currency, merged and ranked.
struct DealEngine {
  let keys: APIKeys
  var fx: FX = .shared

  /// The most extra date pairs searched live (each one is a SerpApi search).
  static let maxFlexibleDates = 4
  /// Countries whose Google Flights is also asked (prices there can differ, as can sellers).
  static let otherMarkets = ["gb", "in", "mx", "de", "th"]
  static let marketsPerSearch = 3
  /// How many of the best hotels get every booking site's price checked.
  static let hotelsCompared = 5

  struct FlightResult {
    var offers: [FlightOffer] = []
    var insights: PriceInsights?
    var calendar: [Date: Double] = [:]
    var googleURL: URL?
    var log: [String] = []
    var warnings: [String] = []
    var serpSearches = 0
  }

  struct HotelResult {
    var hotels: [HotelOffer] = []
    var googleURL: URL?
    var log: [String] = []
    var warnings: [String] = []
    var serpSearches = 0
  }

  typealias Report = @Sendable (String) async -> Void

  /// SerpApi searches a query uses (the other sources are free).
  static func estimatedSerpSearches(_ query: SearchQuery, keys: APIKeys) -> Int {
    guard keys.serpApi != nil else { return 0 }
    var count = 0
    if query.mode.needsFlights {
      count += 1 + min(query.flexDays * 2, maxFlexibleDates)
      if query.trySplitTickets && query.isRoundTrip { count += 2 }
      if query.checkOtherMarkets { count += marketsPerSearch }
    }
    if query.mode.needsHotels {
      count += 2 + (query.includeVacationRentals ? 1 : 0)
      if query.compareAllHotelSites { count += hotelsCompared }
    }
    return count
  }

  static func markets(excluding region: String) -> [String] {
    Array(otherMarkets.filter { $0 != region.lowercased() }.prefix(marketsPerSearch))
  }

  // MARK: - Flights

  private struct Job {
    enum Kind { case main, flexible, splitOut, splitBack, market(String), cached }
    var kind: Kind
    var offers: [FlightOffer] = []
    var insights: PriceInsights?
    var googleURL: URL?
    var serpSearches = 0
    var log: String?
    var warning: String?
  }

  func flights(_ query: SearchQuery, report: @escaping Report) async -> FlightResult {
    var result = FlightResult()
    guard let origin = query.origin, let destination = query.destination else { return result }
    guard keys.hasAnyFlightSource else {
      result.warnings.append("Add at least one flight source in Settings (SerpApi gives the widest coverage).")
      return result
    }
    let origins = Airports.codes(for: origin, nearby: query.includeNearbyAirports)
    let destinations = Airports.codes(for: destination, nearby: query.includeNearbyAirports)
    let tripLength = query.returnDate.map { Fmt.days(from: query.departDate, to: $0) }

    // 1. The free fare calendar: shows the month at a glance and picks which other dates to try.
    if let token = keys.travelpayouts {
      await report("Reading the fare calendar…")
      let tp = Travelpayouts(token: token)
      var months = [query.departDate]
      let monthOfLast = Fmt.addDays(query.flexDays, to: query.departDate)
      if !Calendar.current.isDate(monthOfLast, equalTo: query.departDate, toGranularity: .month) { months.append(monthOfLast) }
      for month in months {
        do {
          let days = try await tp.calendar(origin: origin.code, destination: destination.code, month: month,
                                           tripLength: tripLength, currency: query.currency)
          result.calendar.merge(days) { min($0, $1) }
        } catch {
          result.warnings.append("Fare calendar: \(error.localizedDescription)")
        }
      }
      if !result.calendar.isEmpty { result.log.append("Fare calendar: \(result.calendar.count) days with recent fares") }
    }

    // 2. Which dates to search live.
    let flexibleDates = Self.flexibleDates(for: query, calendar: result.calendar)
    if !flexibleDates.isEmpty {
      let list = flexibleDates.map { Fmt.dayShort.string(from: $0) }.joined(separator: ", ")
      result.log.append("Also trying departures on \(list)")
    }
    if origins.count > 1 || destinations.count > 1 {
      result.log.append("Airports: \(origins.joined(separator: " ")) → \(destinations.joined(separator: " "))")
    }

    // 3. Everything at once.
    await report("Searching \(keys.sourceCount) source\(keys.sourceCount == 1 ? "" : "s")…")
    let jobs = await withTaskGroup(of: Job.self, returning: [Job].self) { group in
      if let key = keys.serpApi {
        let serp = SerpApi(key: key)
        func request(depart: Date, ret: Date?, region: String) -> SerpApi.FlightRequest {
          SerpApi.FlightRequest(origins: origins, destinations: destinations, depart: depart, ret: ret,
                                adults: query.adults, children: query.children, cabin: query.cabin,
                                maxStops: query.maxStops, currency: query.currency, region: region, deep: true)
        }
        group.addTask {
          await Self.serpJob(.main, serp, request(depart: query.departDate, ret: query.returnDate, region: query.region),
                             label: "Google Flights", report: report)
        }
        for day in flexibleDates {
          let ret = tripLength.map { Fmt.addDays($0, to: day) }
          group.addTask {
            await Self.serpJob(.flexible, serp, request(depart: day, ret: ret, region: query.region),
                               label: "Google Flights \(Fmt.dayShort.string(from: day))", report: report)
          }
        }
        if query.trySplitTickets, let ret = query.returnDate {
          var back = request(depart: ret, ret: nil, region: query.region)
          back.origins = destinations
          back.destinations = origins
          group.addTask {
            await Self.serpJob(.splitOut, serp, request(depart: query.departDate, ret: nil, region: query.region),
                               label: "Google Flights one-way out", report: report)
          }
          group.addTask { await Self.serpJob(.splitBack, serp, back, label: "Google Flights one-way back", report: report) }
        }
        if query.checkOtherMarkets {
          for market in Self.markets(excluding: query.region) {
            group.addTask {
              await Self.serpJob(.market(market), serp, request(depart: query.departDate, ret: query.returnDate, region: market),
                                 label: "Google Flights (\(market.uppercased()))", report: report)
            }
          }
        }
      }

      if let token = keys.duffel {
        let duffel = Duffel(token: token)
        func request(depart: Date, ret: Date?, from: String, to: String) -> Duffel.Request {
          Duffel.Request(origin: from, destination: to, depart: depart, ret: ret, adults: query.adults,
                         children: query.children, cabin: query.cabin, maxStops: query.maxStops)
        }
        group.addTask {
          await Self.duffelJob(.main, duffel, request(depart: query.departDate, ret: query.returnDate,
                                                      from: origin.code, to: destination.code), report: report)
        }
        for day in flexibleDates {
          let ret = tripLength.map { Fmt.addDays($0, to: day) }
          group.addTask {
            await Self.duffelJob(.flexible, duffel, request(depart: day, ret: ret, from: origin.code, to: destination.code), report: report)
          }
        }
        if query.trySplitTickets, let ret = query.returnDate {
          group.addTask {
            await Self.duffelJob(.splitOut, duffel, request(depart: query.departDate, ret: nil,
                                                            from: origin.code, to: destination.code), report: report)
          }
          group.addTask {
            await Self.duffelJob(.splitBack, duffel, request(depart: ret, ret: nil, from: destination.code, to: origin.code), report: report)
          }
        }
        // A city search on Duffel covers its airports; nearby airports outside the city get their own.
        if query.includeNearbyAirports {
          let extraOrigins = origins.filter { !Airports.primaryCodes(for: origin).contains($0) }.prefix(2)
          for code in extraOrigins {
            group.addTask {
              await Self.duffelJob(.main, duffel, request(depart: query.departDate, ret: query.returnDate,
                                                          from: code, to: destination.code), report: report)
            }
          }
        }
      }

      if let token = keys.travelpayouts {
        let tp = Travelpayouts(token: token)
        group.addTask {
          var job = Job(kind: .cached)
          do {
            job.offers = try await tp.offers(origin: origin.code, destination: destination.code, depart: query.departDate,
                                             ret: query.returnDate, travelers: query.travelers, currency: query.currency)
            job.log = "Aviasales: \(job.offers.count) recent fares"
          } catch {
            job.warning = "Aviasales: \(error.localizedDescription)"
          }
          await report("Aviasales done")
          return job
        }
      }

      var jobs: [Job] = []
      for await job in group { jobs.append(job) }
      return jobs
    }

    // 4. Combine.
    var offers: [FlightOffer] = []
    var outs: [FlightOffer] = []
    var backs: [FlightOffer] = []
    let primaryOrigins = Airports.primaryCodes(for: origin)
    let primaryDestinations = Airports.primaryCodes(for: destination)
    for job in jobs {
      result.serpSearches += job.serpSearches
      if let log = job.log { result.log.append(log) }
      if let warning = job.warning { result.warnings.append(warning) }
      var batch = job.offers
      for index in batch.indices {
        if !primaryOrigins.contains(batch[index].outbound.fromCode) || !primaryDestinations.contains(batch[index].outbound.toCode) {
          batch[index].tags.insert(.nearbyAirport)
        }
      }
      switch job.kind {
      case .main:
        if result.insights == nil { result.insights = job.insights }
        if result.googleURL == nil { result.googleURL = job.googleURL }
        offers += batch
      case .cached:
        offers += batch
      case .flexible:
        offers += batch.map { var offer = $0; offer.tags.insert(.flexibleDate); return offer }
      case .market(let market):
        offers += batch.map {
          var offer = $0
          offer.tags.insert(.otherMarket)
          offer.notes.append("Price from Google Flights in \(Locale.current.localizedString(forRegionCode: market.uppercased()) ?? market.uppercased()). Booking sites may show it only to visitors from there.")
          return offer
        }
      case .splitOut: outs += batch
      case .splitBack: backs += batch
      }
    }

    offers = await convert(offers, to: query.currency, result: &result)
    outs = await convert(outs, to: query.currency, result: &result)
    backs = await convert(backs, to: query.currency, result: &result)
    offers += Self.splitTickets(outs: outs, backs: backs, query: query)
    if !query.isRoundTrip { offers += outs }

    result.offers = Self.rank(Self.dedupe(offers))
    if let best = result.offers.first {
      result.log.insert("Lowest: \(Fmt.money(best.price, query.currency)) of \(result.offers.count) options", at: 0)
    }
    return result
  }

  private static func serpJob(_ kind: Job.Kind, _ serp: SerpApi, _ request: SerpApi.FlightRequest, label: String,
                              report: Report) async -> Job {
    var job = Job(kind: kind, serpSearches: 1)
    do {
      let page = try await serp.flights(request)
      job.offers = page.offers
      job.insights = page.insights
      job.googleURL = page.googleURL
      job.log = "\(label): \(page.offers.count) options"
    } catch {
      job.warning = "\(label): \(error.localizedDescription)"
    }
    await report("\(label) done")
    return job
  }

  private static func duffelJob(_ kind: Job.Kind, _ duffel: Duffel, _ request: Duffel.Request, report: Report) async -> Job {
    var job = Job(kind: kind)
    let label = "Duffel \(request.origin)→\(request.destination) \(Fmt.dayShort.string(from: request.depart))\(request.ret == nil ? " one-way" : "")"
    do {
      job.offers = try await duffel.flights(request)
      job.log = "\(label): \(job.offers.count) airline fares"
    } catch {
      job.warning = "\(label): \(error.localizedDescription)"
    }
    await report("Duffel done")
    return job
  }

  private func convert(_ offers: [FlightOffer], to currency: String, result: inout FlightResult) async -> [FlightOffer] {
    var converted: [FlightOffer] = []
    var dropped = 0
    for var offer in offers {
      if offer.currency.uppercased() != currency.uppercased() {
        guard let price = await fx.convert(offer.price, from: offer.currency, to: currency) else { dropped += 1; continue }
        offer.notes.append("Priced in \(offer.currency) (\(Fmt.money(offer.price, offer.currency))); converted at today's rate.")
        offer.price = price
        offer.currency = currency
      }
      converted.append(offer)
    }
    if dropped > 0 { result.warnings.append("\(dropped) fares in other currencies were left out (exchange rates unavailable).") }
    return converted
  }

  /// Departure days near the chosen one worth searching live: the cheapest days on the fare
  /// calendar, or without it the closest days.
  static func flexibleDates(for query: SearchQuery, calendar: [Date: Double]) -> [Date] {
    guard query.flexDays > 0 else { return [] }
    let today = Calendar.current.startOfDay(for: Date())
    let base = Calendar.current.startOfDay(for: query.departDate)
    let candidates = (-query.flexDays...query.flexDays)
      .filter { $0 != 0 }
      .map { (shift: $0, day: Fmt.addDays($0, to: base)) }
      .filter { $0.day >= today }
    let ranked = candidates.sorted { a, b in
      let priceA = calendar[a.day] ?? .infinity
      let priceB = calendar[b.day] ?? .infinity
      if priceA != priceB { return priceA < priceB }
      return abs(a.shift) < abs(b.shift)
    }
    var chosen = ranked.prefix(maxFlexibleDates)
    // With calendar prices, skip days clearly dearer than the chosen day.
    if let basePrice = calendar[base] {
      let cheaper = chosen.filter { (calendar[$0.day] ?? 0) <= basePrice * 1.05 }
      if !cheaper.isEmpty { chosen = cheaper.prefix(maxFlexibleDates) }
    }
    return chosen.map { $0.day }.sorted()
  }

  /// Pairs the cheapest one-way tickets each way into round trips.
  static func splitTickets(outs: [FlightOffer], backs: [FlightOffer], query: SearchQuery) -> [FlightOffer] {
    guard query.isRoundTrip, !outs.isEmpty, !backs.isEmpty else { return [] }
    let bestOuts = outs.sorted { $0.price < $1.price }.prefix(4)
    let bestBacks = backs.sorted { $0.price < $1.price }.prefix(4)
    var combos: [FlightOffer] = []
    for out in bestOuts {
      for back in bestBacks {
        // The return must leave after the outbound lands.
        if let arrives = out.outbound.arrives, let departs = back.outbound.departs, departs <= arrives { continue }
        var offer = FlightOffer(
          id: "SPLIT|" + out.outbound.key + "|" + back.outbound.key,
          price: out.price + back.price,
          currency: out.currency,
          outbound: out.outbound,
          inbound: back.outbound,
          isRoundTrip: true,
          departDate: query.departDate,
          returnDate: query.returnDate,
          providers: Array(Set(out.providers + back.providers)).sorted { $0.rawValue < $1.rawValue },
          tags: out.tags.union(back.tags).union([.splitTicket]).subtracting([.cheapest, .fastest, .bestValue]),
          parts: [out, back])
        offer.notes.append("Two separate one-way tickets. Book both; if the first flight is late, the second airline doesn't have to rebook you.")
        combos.append(offer)
      }
    }
    return Array(combos.sorted { $0.price < $1.price }.prefix(6))
  }

  /// One entry per itinerary: the lowest price wins, and every source that found it is kept.
  static func dedupe(_ offers: [FlightOffer]) -> [FlightOffer] {
    var best: [String: FlightOffer] = [:]
    var order: [String] = []
    for offer in offers {
      let key = offer.dedupeKey
      guard let existing = best[key] else {
        best[key] = offer
        order.append(key)
        continue
      }
      var winner = offer.price < existing.price ? offer : existing
      let loser = offer.price < existing.price ? existing : offer
      winner.providers = Array(Set(winner.providers + loser.providers)).sorted { $0.rawValue < $1.rawValue }
      // A tag like "other date" belongs to the winning price; sources' tags merge.
      winner.tags.formUnion(loser.tags.intersection([.airlineDirect]))
      if winner.bookings.isEmpty { winner.bookings = loser.bookings }
      if winner.serpParams == nil {
        winner.serpParams = loser.serpParams
        winner.serpReturnToken = loser.serpReturnToken
        winner.serpBookingToken = loser.serpBookingToken
      }
      best[key] = winner
    }
    return order.compactMap { best[$0] }
  }

  /// Sorted by price, with the cheapest, fastest and best-value options marked.
  static func rank(_ offers: [FlightOffer]) -> [FlightOffer] {
    var sorted = offers.sorted { $0.price < $1.price }
    guard !sorted.isEmpty else { return sorted }
    for index in sorted.indices {
      sorted[index].tags.subtract([.cheapest, .fastest, .bestValue])
      if sorted[index].maxStops == 0 { sorted[index].tags.insert(.nonstop) }
    }
    sorted[0].tags.insert(.cheapest)
    let live = sorted.indices.filter { !sorted[$0].tags.contains(.cached) && sorted[$0].totalMinutes > 0 }
    if let fastest = live.min(by: { sorted[$0].totalMinutes < sorted[$1].totalMinutes }) {
      sorted[fastest].tags.insert(.fastest)
    }
    if let value = live.min(by: { valueScore(sorted[$0]) < valueScore(sorted[$1]) }) {
      sorted[value].tags.insert(.bestValue)
    }
    return sorted
  }

  /// Price plus a cost for time spent travelling and for each stop.
  static func valueScore(_ offer: FlightOffer) -> Double {
    let hours = Double(offer.totalMinutes) / 60
    let perHour = max(12, offer.price / 60)
    return offer.price + hours * perHour + Double(offer.maxStops) * perHour * 1.5
  }

  // MARK: - Hotels

  func hotels(_ query: SearchQuery, report: @escaping Report) async -> HotelResult {
    var result = HotelResult()
    guard let key = keys.serpApi else {
      result.warnings.append("Hotel prices come from Google Hotels: add a SerpApi key in Settings.")
      return result
    }
    let serp = SerpApi(key: key)
    await report("Searching Google Hotels…")
    var passes: [(SerpApi.HotelSort, Bool, String)] = [
      (.lowestPrice, false, "lowest price"), (.relevance, false, "top picks"),
    ]
    if query.includeVacationRentals { passes.append((.lowestPrice, true, "vacation rentals")) }

    let pages = await withTaskGroup(of: (SerpApi.HotelPage?, String, String?).self, returning: [(SerpApi.HotelPage?, String, String?)].self) { group in
      for (sort, rentals, label) in passes {
        group.addTask {
          do {
            let page = try await serp.hotels(query, sort: sort, rentals: rentals)
            await report("Hotels: \(label) done")
            return (page, label, nil)
          } catch {
            return (nil, label, error.localizedDescription)
          }
        }
      }
      var pages: [(SerpApi.HotelPage?, String, String?)] = []
      for await page in group { pages.append(page) }
      return pages
    }

    var merged: [String: HotelOffer] = [:]
    for (page, label, error) in pages {
      result.serpSearches += 1
      if let error { result.warnings.append("Google Hotels (\(label)): \(error)"); continue }
      guard let page else { continue }
      if result.googleURL == nil { result.googleURL = page.googleURL }
      result.log.append("Google Hotels (\(label)): \(page.hotels.count) places")
      for hotel in page.hotels {
        if var existing = merged[hotel.id] {
          for source in hotel.sources where !existing.sources.contains(where: { $0.source == source.source }) {
            existing.sources.append(source)
          }
          if hotel.total < existing.total { existing.total = hotel.total; existing.nightly = hotel.nightly }
          existing.tags.formUnion(hotel.tags)
          merged[hotel.id] = existing
        } else {
          merged[hotel.id] = hotel
        }
      }
    }
    var hotels = Array(merged.values).filter { hotel in
      (query.minRating == 0 || (hotel.rating ?? 0) >= query.minRating)
        && (query.minStars < 2 || hotel.tags.contains(.vacationRental) || (hotel.stars ?? 0) >= query.minStars)
    }

    // Every booking site's price for the strongest candidates.
    if query.compareAllHotelSites, !hotels.isEmpty {
      let candidates = Array(hotels.sorted { $0.valueScore < $1.valueScore }.prefix(Self.hotelsCompared))
      await report("Comparing every booking site for the top \(candidates.count)…")
      let detailed = await withTaskGroup(of: HotelOffer?.self, returning: [HotelOffer].self) { group in
        for hotel in candidates where hotel.propertyToken != nil {
          group.addTask { try? await serp.hotelDetails(hotel) }
        }
        var list: [HotelOffer] = []
        for await hotel in group { if let hotel { list.append(hotel) } }
        return list
      }
      result.serpSearches += candidates.filter { $0.propertyToken != nil }.count
      for hotel in detailed {
        if let index = hotels.firstIndex(where: { $0.id == hotel.id }) { hotels[index] = hotel }
      }
      let siteCount = Set(detailed.flatMap { $0.sources.map(\.source) }).count
      result.log.append("Compared \(siteCount) booking sites for the top \(detailed.count) places")
    }

    result.hotels = Self.rankHotels(hotels)
    if let best = result.hotels.first {
      result.log.insert("Lowest stay: \(Fmt.money(best.total, query.currency)) of \(result.hotels.count) places", at: 0)
    }
    return result
  }

  static func rankHotels(_ hotels: [HotelOffer]) -> [HotelOffer] {
    var sorted = hotels.sorted { $0.total < $1.total }
    guard !sorted.isEmpty else { return sorted }
    for index in sorted.indices { sorted[index].tags.subtract([.cheapest, .bestValue, .topRated]) }
    sorted[0].tags.insert(.cheapest)
    if let value = sorted.indices.min(by: { sorted[$0].valueScore < sorted[$1].valueScore }) {
      sorted[value].tags.insert(.bestValue)
    }
    let rated = sorted.indices.filter { (sorted[$0].reviews ?? 0) >= 50 }
    if let top = rated.max(by: { (sorted[$0].rating ?? 0) < (sorted[$1].rating ?? 0) }) {
      sorted[top].tags.insert(.topRated)
    }
    return sorted
  }

  // MARK: - Packages

  /// The best flight + hotel combinations. Bundled package rates aren't offered through any
  /// public API, so packages are built from the cheapest separately booked parts.
  static func packages(flights: [FlightOffer], hotels: [HotelOffer], currency: String) -> [PackageDeal] {
    let flightChoices = Array(flights.prefix(3)) + flights.filter { $0.tags.contains(.bestValue) || $0.tags.contains(.nonstop) }.prefix(3)
    let cheapestHotels = hotels.sorted { $0.total < $1.total }.prefix(6)
    let valueHotels = hotels.sorted { $0.valueScore < $1.valueScore }.prefix(6)
    var deals: [String: PackageDeal] = [:]
    for flight in flightChoices {
      for hotel in Array(cheapestHotels) + Array(valueHotels) {
        let deal = PackageDeal(flight: flight, hotel: hotel, currency: currency)
        deals[deal.id] = deal
      }
    }
    var sorted = deals.values.sorted { $0.total < $1.total }
    guard !sorted.isEmpty else { return [] }
    sorted[0].tags.insert(.cheapest)
    if let value = sorted.indices.min(by: {
      sorted[$0].hotel.valueScore + valueScore(sorted[$0].flight) < sorted[$1].hotel.valueScore + valueScore(sorted[$1].flight)
    }) {
      sorted[value].tags.insert(.bestValue)
    }
    return Array(sorted.prefix(25))
  }
}
