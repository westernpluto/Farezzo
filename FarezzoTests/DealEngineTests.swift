import XCTest
@testable import Farezzo

final class DealEngineTests: XCTestCase {
  private func json(_ text: String) throws -> JSONValue { try JSONValue(data: Data(text.utf8)) }

  private func segment(_ from: String, _ to: String, _ departs: String, _ arrives: String, number: String = "XX 1") -> FlightSegment {
    let d = Fmt.naive(departs)!
    let a = Fmt.naive(arrives)!
    return FlightSegment(fromCode: from, fromName: from, toCode: to, toName: to, departs: d, arrives: a,
                         airline: "Test Air", flightNumber: number, durationMinutes: Int(a.timeIntervalSince(d) / 60))
  }

  private func offer(_ price: Double, out: FlightLeg, back: FlightLeg? = nil, provider: Provider = .googleFlights) -> FlightOffer {
    var offer = FlightOffer(id: "", price: price, currency: "USD", outbound: out, inbound: back, isRoundTrip: back != nil,
                            departDate: Date(), returnDate: nil, providers: [provider])
    offer.id = offer.dedupeKey
    return offer
  }

  func testNaiveTimesKeepTheLocalClock() {
    let date = Fmt.naive("2026-12-01 08:05")!
    XCTAssertEqual(Fmt.time.timeZone.identifier, "UTC")
    XCTAssertEqual(Fmt.utcCalendar.component(.hour, from: date), 8)
    XCTAssertEqual(Fmt.naive("2026-12-01T08:05:00+03:00"), date)
    XCTAssertEqual(Fmt.naive("2026-12-01T08:05:00"), date)
  }

  func testISODurations() {
    XCTAssertEqual(Fmt.isoDurationMinutes("PT5H30M"), 330)
    XCTAssertEqual(Fmt.isoDurationMinutes("P1DT2H"), 1560)
    XCTAssertEqual(Fmt.isoDurationMinutes("PT45M"), 45)
    XCTAssertNil(Fmt.isoDurationMinutes("5h"))
  }

  func testJSONValueIsForgiving() throws {
    let value = try json(#"{"a": {"b": [1, "2", "$1,234"]}, "n": null}"#)
    XCTAssertEqual(value["a"]["b"][0].double, 1)
    XCTAssertEqual(value["a"]["b"][1].int, 2)
    XCTAssertEqual(value["a"]["b"][2].double, 1234)
    XCTAssertTrue(value["n"].isNull)
    XCTAssertNil(value["missing"]["deeper"][3].string)
  }

  func testCityExpandsToAllAirportsAndNearby() {
    let nyc = Place(code: "NYC", name: "New York", kind: .city)
    XCTAssertEqual(Airports.codes(for: nyc, nearby: false), ["JFK", "EWR", "LGA"])
    let wide = Airports.codes(for: nyc, nearby: true)
    XCTAssertTrue(wide.contains("HPN"))
    XCTAssertLessThanOrEqual(wide.count, 7)
    let jfk = Place(code: "JFK", name: "JFK", kind: .airport)
    XCTAssertEqual(Airports.codes(for: jfk, nearby: false), ["JFK"])
    XCTAssertTrue(Airports.codes(for: jfk, nearby: true).contains("EWR"))
  }

  func testSerpFlightsParse() throws {
    let page = SerpApi.parseFlightPage(try json(#"""
    {
      "search_metadata": {"google_flights_url": "https://www.google.com/travel/flights?x=1"},
      "best_flights": [{
        "flights": [
          {"departure_airport": {"name": "JFK Intl", "id": "JFK", "time": "2026-12-01 08:00"},
           "arrival_airport": {"name": "Heathrow", "id": "LHR", "time": "2026-12-01 20:00"},
           "duration": 420, "airline": "Test Air", "flight_number": "TA 100", "airline_logo": "https://x/logo.png"}
        ],
        "total_duration": 420, "price": 512, "departure_token": "DEP"
      }],
      "other_flights": [{"flights": [], "price": 1}],
      "price_insights": {"lowest_price": 512, "price_level": "low", "typical_price_range": [600, 900],
                         "price_history": [[1700000000, 700]]}
    }
    """#), params: ["engine": "google_flights"], currency: "USD", depart: Date(), ret: Date())
    XCTAssertEqual(page.offers.count, 1)
    let offer = try XCTUnwrap(page.offers.first)
    XCTAssertEqual(offer.price, 512)
    XCTAssertEqual(offer.outbound.stops, 0)
    XCTAssertEqual(offer.outbound.fromCode, "JFK")
    XCTAssertEqual(offer.serpReturnToken, "DEP")
    XCTAssertTrue(offer.isRoundTrip)
    XCTAssertEqual(page.insights?.level, "low")
    XCTAssertEqual(page.insights?.typicalHigh, 900)
    XCTAssertEqual(page.insights?.history.count, 1)
  }

  func testBookingOptionsParse() throws {
    let links = SerpApi.parseBookingOptions(try json(#"""
    {"booking_options": [
      {"together": {"book_with": "Expensive", "price": 700, "booking_request": {"url": "https://a.example", "post_data": "x=1"}}},
      {"together": {"book_with": "Cheap", "price": 500, "booking_request": {"url": "https://b.example"}}}
    ]}
    """#))
    XCTAssertEqual(links.map(\.label), ["Cheap", "Expensive"])
    XCTAssertEqual(links.last?.postBody, "x=1")
  }

  func testDuffelOfferParse() throws {
    let request = Duffel.Request(origin: "JFK", destination: "LHR", depart: Date(), ret: nil, adults: 1, children: 0, cabin: .economy, maxStops: nil)
    let parsed = Duffel.parseOffer(try json(#"""
    {"total_amount": "432.10", "total_currency": "GBP", "owner": {"name": "Test Air"},
     "slices": [{"duration": "PT9H", "segments": [
       {"departing_at": "2026-12-01T08:00:00", "arriving_at": "2026-12-01T12:00:00",
        "origin": {"iata_code": "JFK", "name": "JFK"}, "destination": {"iata_code": "KEF", "name": "Keflavik"},
        "marketing_carrier": {"name": "Test Air", "iata_code": "TA"}, "marketing_carrier_flight_number": "1", "duration": "PT4H"},
       {"departing_at": "2026-12-01T14:00:00", "arriving_at": "2026-12-01T17:00:00",
        "origin": {"iata_code": "KEF", "name": "Keflavik"}, "destination": {"iata_code": "LHR", "name": "Heathrow"},
        "marketing_carrier": {"name": "Test Air", "iata_code": "TA"}, "marketing_carrier_flight_number": "2", "duration": "PT3H"}
     ]}]}
    """#), request: request)
    let offer = try XCTUnwrap(parsed)
    XCTAssertEqual(offer.price, 432.10, accuracy: 0.001)
    XCTAssertEqual(offer.currency, "GBP")
    XCTAssertEqual(offer.outbound.stops, 1)
    XCTAssertEqual(offer.outbound.layovers.first?.minutes, 120)
    XCTAssertEqual(offer.outbound.durationMinutes, 540)
    XCTAssertTrue(offer.tags.contains(.airlineDirect))
  }

  func testDedupeKeepsLowestPriceAndAllSources() {
    let leg = FlightLeg.make(segments: [segment("JFK", "LHR", "2026-12-01 08:00", "2026-12-01 20:00", number: "TA 1")])
    let a = offer(600, out: leg, provider: .googleFlights)
    let b = offer(550, out: leg, provider: .duffel)
    let merged = DealEngine.dedupe([a, b])
    XCTAssertEqual(merged.count, 1)
    XCTAssertEqual(merged.first?.price, 550)
    XCTAssertEqual(Set(merged.first?.providers ?? []), [.googleFlights, .duffel])
  }

  func testSplitTicketsPairCheapestOneWays() {
    var query = SearchQuery()
    query.returnDate = Fmt.addDays(7, to: query.departDate)
    let out1 = offer(200, out: FlightLeg.make(segments: [segment("JFK", "LHR", "2026-12-01 08:00", "2026-12-01 20:00", number: "A 1")]))
    let out2 = offer(150, out: FlightLeg.make(segments: [segment("EWR", "LHR", "2026-12-01 09:00", "2026-12-01 21:00", number: "B 2")]))
    let back = offer(180, out: FlightLeg.make(segments: [segment("LHR", "JFK", "2026-12-08 10:00", "2026-12-08 13:00", number: "C 3")]))
    let combos = DealEngine.splitTickets(outs: [out1, out2], backs: [back], query: query)
    XCTAssertEqual(combos.first?.price, 330)
    XCTAssertEqual(combos.first?.parts.count, 2)
    XCTAssertTrue(combos.first?.tags.contains(.splitTicket) ?? false)
    XCTAssertEqual(combos.first?.inbound?.fromCode, "LHR")
  }

  func testRankMarksCheapestFastestAndNonstop() {
    let slowCheap = offer(300, out: FlightLeg.make(segments: [
      segment("JFK", "KEF", "2026-12-01 08:00", "2026-12-01 14:00", number: "A 1"),
      segment("KEF", "LHR", "2026-12-01 20:00", "2026-12-02 01:00", number: "A 2"),
    ]))
    let fast = offer(420, out: FlightLeg.make(segments: [segment("JFK", "LHR", "2026-12-01 08:00", "2026-12-01 15:00", number: "B 1")]))
    let ranked = DealEngine.rank([fast, slowCheap])
    XCTAssertEqual(ranked.first?.price, 300)
    XCTAssertTrue(ranked[0].tags.contains(.cheapest))
    XCTAssertTrue(ranked[1].tags.contains(.fastest))
    XCTAssertTrue(ranked[1].tags.contains(.nonstop))
  }

  func testFlexibleDatesPreferCheapCalendarDays() {
    var query = SearchQuery()
    query.departDate = Calendar.current.startOfDay(for: Fmt.addDays(30, to: Date()))
    query.flexDays = 3
    let base = query.departDate
    var calendar: [Date: Double] = [base: 500]
    calendar[Fmt.addDays(2, to: base)] = 300
    calendar[Fmt.addDays(-1, to: base)] = 350
    calendar[Fmt.addDays(1, to: base)] = 900
    let dates = DealEngine.flexibleDates(for: query, calendar: calendar)
    XCTAssertTrue(dates.contains(Fmt.addDays(2, to: base)))
    XCTAssertTrue(dates.contains(Fmt.addDays(-1, to: base)))
    XCTAssertFalse(dates.contains(Fmt.addDays(1, to: base)))
    XCTAssertLessThanOrEqual(dates.count, DealEngine.maxFlexibleDates)
  }

  func testHotelParseFoldsInAdsAndSources() throws {
    var query = SearchQuery()
    query.mode = .hotels
    query.destination = Place(code: "LIS", name: "Lisbon", kind: .city)
    query.returnDate = Fmt.addDays(2, to: query.departDate)
    let page = SerpApi.parseHotelPage(try json(#"""
    {"properties": [
      {"name": "Casa Azul", "property_token": "T1", "overall_rating": 4.6, "reviews": 900, "extracted_hotel_class": 4,
       "rate_per_night": {"extracted_lowest": 120}, "total_rate": {"extracted_lowest": 240},
       "prices": [{"source": "Booking.com", "rate_per_night": {"extracted_lowest": 120}}]}
    ],
     "ads": [{"name": "Casa Azul", "source": "Hotels.com", "extracted_price": 100, "property_token": "T1"}]}
    """#), params: [:], query: query, rentals: false)
    let hotel = try XCTUnwrap(page.hotels.first)
    XCTAssertEqual(hotel.total, 200)
    XCTAssertEqual(hotel.sources.count, 2)
    XCTAssertEqual(hotel.cheapestSource?.source, "Hotels.com")
  }

  func testPackagesAreSortedByTotal() {
    let leg = FlightLeg.make(segments: [segment("JFK", "LHR", "2026-12-01 08:00", "2026-12-01 20:00")])
    let flights = DealEngine.rank([offer(500, out: leg)])
    let hotel = { (id: String, total: Double) in
      HotelOffer(id: id, name: id, total: total, currency: "USD", nights: 3, checkIn: Date(), checkOut: Date())
    }
    let deals = DealEngine.packages(flights: flights, hotels: [hotel("a", 400), hotel("b", 300)], currency: "USD")
    XCTAssertEqual(deals.first?.total, 800)
    XCTAssertTrue(deals.first?.tags.contains(.cheapest) ?? false)
  }
}
