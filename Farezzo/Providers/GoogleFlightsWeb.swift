import Foundation

/// No-key mode for flights: reads the public Google Flights results page on this iPhone.
/// The search goes in the page address (`tfs`, Google's own encoding of a flight search), and
/// each result is read from the description Google gives screen readers ("From 512 US dollars
/// round trip total. Nonstop flight with … Leaves … at 8:00 PM on Tuesday, December 1 and
/// arrives …"), which changes far less often than the page's layout.
enum GoogleFlightsWeb {
  // MARK: - Address

  private static func varint(_ value: UInt64) -> [UInt8] {
    var value = value
    var bytes: [UInt8] = []
    repeat {
      var byte = UInt8(value & 0x7F)
      value >>= 7
      if value != 0 { byte |= 0x80 }
      bytes.append(byte)
    } while value != 0
    return bytes
  }

  private static func field(_ number: Int, varint value: UInt64) -> [UInt8] {
    varint(UInt64(number << 3)) + varint(value)
  }

  private static func field(_ number: Int, bytes: [UInt8]) -> [UInt8] {
    varint(UInt64(number << 3 | 2)) + varint(UInt64(bytes.count)) + bytes
  }

  private static func leg(date: Date, from: [String], to: [String], maxStops: Int?) -> [UInt8] {
    var bytes = field(2, bytes: Array(Fmt.ymd.string(from: date).utf8))
    if let maxStops { bytes += field(5, varint: UInt64(maxStops)) }
    for code in from { bytes += field(13, bytes: field(2, bytes: Array(code.utf8))) }
    for code in to { bytes += field(14, bytes: field(2, bytes: Array(code.utf8))) }
    return bytes
  }

  /// The search, encoded the way Google Flights' own links are. The first airport of each side
  /// is the one asked for; it goes last so it wins if Google only takes one.
  static func tfs(_ request: SerpApi.FlightRequest) -> String {
    let origins = Array(request.origins.reversed())
    let destinations = Array(request.destinations.reversed())
    var info = field(3, bytes: leg(date: request.depart, from: origins, to: destinations, maxStops: request.maxStops))
    if let ret = request.ret {
      info += field(3, bytes: leg(date: ret, from: destinations, to: origins, maxStops: request.maxStops))
    }
    for _ in 0..<max(1, request.adults) { info += field(8, varint: 1) }
    for _ in 0..<request.children { info += field(8, varint: 2) }
    info += field(9, varint: UInt64(request.cabin.rawValue))
    info += field(19, varint: request.ret == nil ? 2 : 1)
    return Data(info).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  static func url(for request: SerpApi.FlightRequest) -> URL {
    HTTP.url("https://www.google.com/travel/flights/search", [
      ("tfs", tfs(request)), ("hl", "en"), ("curr", request.currency.uppercased()), ("gl", request.region.uppercased()),
    ])
  }

  // MARK: - Reading the page

  static let readyScript = """
  (() => {
    const t = document.body ? document.body.innerText : '';
    return document.querySelectorAll('[aria-label^="From "]').length > 2
      || /No results returned|no flights found|There are no flights/i.test(t)
      || location.href.indexOf('/sorry/') >= 0 || location.host.indexOf('consent.') === 0
      || /unusual traffic/i.test(t);
  })()
  """

  static let expandScript = """
  (() => {
    const b = Array.from(document.querySelectorAll('button, [role="button"]'))
      .find(x => /more flights/i.test((x.getAttribute('aria-label') || '') + ' ' + (x.innerText || '')));
    if (b) { b.click(); return true; }
    return false;
  })()
  """

  static let extractScript = """
  (() => {
    const body = document.body ? document.body.innerText : '';
    const seen = new Set();
    const items = [];
    document.querySelectorAll('[aria-label^="From "]').forEach(el => {
      const label = el.getAttribute('aria-label') || '';
      if (label.indexOf('Leaves') < 0 || seen.has(label)) return;
      seen.add(label);
      const row = el.closest('li') || el.parentElement || el;
      const img = row.querySelector('img');
      items.push({ label: label, text: row.innerText || '', logo: img ? img.src : null });
    });
    const level = body.match(/prices are currently (low|typical|high)/i);
    const range = body.match(/usually cost between[^\\n]{0,40}/i);
    return JSON.stringify({
      items: items,
      level: level ? level[1].toLowerCase() : null,
      range: range ? range[0] : null,
      captcha: location.href.indexOf('/sorry/') >= 0 || /unusual traffic/i.test(body),
      consent: location.host.indexOf('consent.') === 0
    });
  })()
  """

  @MainActor
  static func flights(_ request: SerpApi.FlightRequest) async throws -> SerpApi.FlightPage {
    let url = url(for: request)
    let json = try await WebPageReader.shared.read(url, ready: readyScript, extract: extractScript, expand: expandScript)
    return parsePage(json, request: request, url: url)
  }

  static func parsePage(_ json: JSONValue, request: SerpApi.FlightRequest, url: URL) -> SerpApi.FlightPage {
    var page = SerpApi.FlightPage()
    page.googleURL = url
    if let level = json["level"].string {
      let numbers = Rx.all(#"\d[\d,]*"#, json["range"].string ?? "").compactMap { $0[0] }.compactMap {
        Double($0.replacingOccurrences(of: ",", with: ""))
      }
      page.insights = PriceInsights(lowest: nil, level: level,
                                    typicalLow: numbers.count >= 2 ? numbers[0] : nil,
                                    typicalHigh: numbers.count >= 2 ? numbers[1] : nil)
    }
    for item in json["items"].array {
      guard let label = item["label"].string,
            let parsed = parseItem(label: label, text: item["text"].string ?? "", logo: item["logo"].url,
                                   searchDate: request.depart) else { continue }
      var offer = FlightOffer(
        id: "",
        price: parsed.price,
        currency: request.currency.uppercased(),
        outbound: parsed.leg,
        inbound: nil,
        isRoundTrip: request.ret != nil,
        departDate: request.depart,
        returnDate: request.ret,
        providers: [.googleFlights],
        bookings: [BookingLink(label: "Google Flights", url: url)])
      if request.ret != nil {
        offer.notes.append("Lowest round-trip price with this outbound flight. Pick your return flight on Google Flights.")
      }
      offer.id = offer.dedupeKey
      page.offers.append(offer)
    }
    return page
  }

  /// One result row: its screen-reader description plus its visible text (for airport codes).
  static func parseItem(label rawLabel: String, text rawText: String, logo: URL?, searchDate: Date) -> (price: Double, leg: FlightLeg)? {
    let label = Rx.normalizeSpaces(rawLabel)
    let text = Rx.normalizeSpaces(rawText)
    guard let price = Rx.match(#"From ([0-9][0-9,]*(?:\.[0-9]+)?)"#, label)?[1]
            .flatMap({ Double($0.replacingOccurrences(of: ",", with: "")) }),
          let times = Rx.match(#"Leaves (.+?) at (\d{1,2}:\d{2} ?[AP]M) on [A-Za-z]+, ([A-Za-z]+ \d{1,2}) and arrives at (.+?) at (\d{1,2}:\d{2} ?[AP]M) on [A-Za-z]+, ([A-Za-z]+ \d{1,2})"#, label),
          let departs = date(day: times[3], time: times[2], near: searchDate),
          let arrivesRaw = date(day: times[6], time: times[5], near: searchDate)
    else { return nil }
    // A late-December trip arriving in January belongs to the next year.
    let arrives = arrivesRaw < departs ? (Fmt.utcCalendar.date(byAdding: .year, value: 1, to: arrivesRaw) ?? arrivesRaw) : arrivesRaw

    let stops: Int
    if label.range(of: "Nonstop", options: .caseInsensitive) != nil {
      stops = 0
    } else {
      stops = Rx.match(#"(\d+) stops? flight"#, label)?[1].flatMap { Int($0) } ?? 0
    }
    var airlines = Rx.match(#"flight with (.+?)\."#, label)?[1] ?? ""
    if let operated = airlines.range(of: " Operated by", options: .caseInsensitive) {
      airlines = String(airlines[..<operated.lowerBound])
    }
    let total: Int = {
      if let found = Rx.match(#"Total duration ([0-9 hrmin]+)"#, label)?[1] { return Rx.minutes(found) }
      return Int(arrives.timeIntervalSince(departs) / 60)
    }()
    let layovers = Rx.all(#"Layover \(\d+ of \d+\) is an? (.+?) (overnight )?layover at (.+?)\."#, label).map {
      Layover(code: "", name: $0[3] ?? "", minutes: Rx.minutes($0[1] ?? ""), overnight: $0[2] != nil)
    }
    let codes = Rx.match(#"\b([A-Z]{3}) ?[–-] ?([A-Z]{3})\b"#, text, caseSensitive: true)
    let airlineName = airlines.isEmpty ? "Airline" : airlines
    let segment = FlightSegment(
      fromCode: codes?[1] ?? "",
      fromName: times[1] ?? "",
      toCode: codes?[2] ?? "",
      toName: times[4] ?? "",
      departs: departs,
      arrives: arrives,
      airline: airlineName,
      flightNumber: airlineName,
      logo: logo,
      durationMinutes: total)
    let leg = FlightLeg(segments: [segment], layovers: layovers, durationMinutes: total, unlistedStops: stops)
    return (price, leg)
  }

  private static let dayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")!
    formatter.dateFormat = "MMMM d yyyy h:mm a"
    return formatter
  }()

  /// "December 1" + "8:05 PM", in the year that puts it closest to the search date.
  static func date(day: String?, time: String?, near searchDate: Date) -> Date? {
    guard let day, let time else { return nil }
    let reference = Fmt.naive(Fmt.ymd.string(from: searchDate)) ?? searchDate
    let year = Fmt.utcCalendar.component(.year, from: reference)
    let normalizedTime = time.contains(" ") ? time : time.replacingOccurrences(of: "AM", with: " AM").replacingOccurrences(of: "PM", with: " PM")
    let candidates = [year - 1, year, year + 1].compactMap { dayFormatter.date(from: "\(day) \($0) \(normalizedTime)") }
    return candidates.min { abs($0.timeIntervalSince(reference)) < abs($1.timeIntervalSince(reference)) }
  }
}
