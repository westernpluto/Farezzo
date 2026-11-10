import Foundation
import Observation

/// One search's results, as the results screen shows them.
@MainActor
@Observable
final class SearchSession {
  enum Phase: Equatable { case idle, searching, done }

  var query: SearchQuery
  var phase: Phase = .idle
  var status = ""
  var finishedSteps = 0
  var flights: [FlightOffer] = []
  var hotels: [HotelOffer] = []
  var packages: [PackageDeal] = []
  var insights: PriceInsights?
  var calendar: [Date: Double] = [:]
  var googleFlightsURL: URL?
  var googleHotelsURL: URL?
  var log: [String] = []
  var warnings: [String] = []
  var serpSearches = 0
  /// A site asked to confirm a person is there (no-key mode): the page to show them.
  var humanCheck: URL?

  private var searchTask: Task<Void, Never>?

  init(query: SearchQuery) {
    self.query = query
  }

  /// Starts the search once. It runs on its own task, so leaving the screen (to open a result)
  /// doesn't cancel it, and coming back doesn't start it again.
  func startIfNeeded() {
    guard phase == .idle, searchTask == nil else { return }
    searchTask = Task { [weak self] in
      await self?.run()
      self?.searchTask = nil
    }
  }

  var bestPrice: Double? {
    switch query.mode {
    case .flights: return flights.first?.price
    case .hotels: return hotels.first?.total
    case .package: return packages.first?.total
    }
  }

  var isEmpty: Bool {
    switch query.mode {
    case .flights: return flights.isEmpty
    case .hotels: return hotels.isEmpty
    case .package: return packages.isEmpty && flights.isEmpty && hotels.isEmpty
    }
  }

  func run() async {
    phase = .searching
    finishedSteps = 0
    flights = []; hotels = []; packages = []; log = []; warnings = []; insights = nil; serpSearches = 0; humanCheck = nil
    let engine = DealEngine(keys: APIKeys.load())
    let query = self.query
    let report: DealEngine.Report = { [weak self] message in
      await MainActor.run {
        self?.status = message
        self?.finishedSteps += 1
      }
    }

    async let flightResult = Self.flights(engine, query, report)
    async let hotelResult = Self.hotels(engine, query, report)
    let f = await flightResult
    let h = await hotelResult

    if let f {
      flights = f.offers
      insights = f.insights
      calendar = f.calendar
      googleFlightsURL = f.googleURL
      log += f.log
      warnings += f.warnings
      serpSearches += f.serpSearches
      humanCheck = humanCheck ?? f.humanCheck
    }
    if let h {
      hotels = h.hotels
      googleHotelsURL = h.googleURL
      log += h.log
      warnings += h.warnings
      serpSearches += h.serpSearches
      humanCheck = humanCheck ?? h.humanCheck
    }
    if query.mode == .package {
      packages = DealEngine.packages(flights: flights, hotels: hotels, currency: query.currency)
    }
    if serpSearches > 0 { log.append("Used \(serpSearches) SerpApi searches") }
    status = ""
    phase = .done
  }

  private nonisolated static func flights(_ engine: DealEngine, _ query: SearchQuery,
                                          _ report: @escaping DealEngine.Report) async -> DealEngine.FlightResult? {
    guard query.mode.needsFlights else { return nil }
    return await engine.flights(query, report: report)
  }

  private nonisolated static func hotels(_ engine: DealEngine, _ query: SearchQuery,
                                         _ report: @escaping DealEngine.Report) async -> DealEngine.HotelResult? {
    guard query.mode.needsHotels else { return nil }
    return await engine.hotels(query, report: report)
  }

  /// Same search, other dates (from the fare calendar).
  func rerun(departing day: Date) async {
    if let returnDate = query.returnDate {
      let length = Fmt.days(from: query.departDate, to: returnDate)
      query.returnDate = Fmt.addDays(length, to: day)
    }
    query.departDate = day
    await run()
  }
}
