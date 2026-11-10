import Foundation

/// No-key mode for stays: reads Booking.com's public search results on this iPhone. Booking.com
/// takes exact dates and guests in the page address and labels each result card for testing
/// (`data-testid`), which keeps reading it dependable. It lists hotels, apartments and other
/// rentals together.
enum BookingWeb {
  enum Order: String { case lowestPrice = "price", popular = "popularity", topReviewed = "bayesian_review_score" }

  static func url(for query: SearchQuery, order: Order) -> URL {
    var params: [(String, String)] = [
      ("ss", query.destination?.hotelQuery ?? ""),
      ("checkin", Fmt.ymd.string(from: query.departDate)),
      ("checkout", Fmt.ymd.string(from: query.checkOut)),
      ("group_adults", "\(max(1, query.adults))"),
      ("group_children", "\(query.children)"),
      ("no_rooms", "1"),
      ("selected_currency", query.currency.uppercased()),
      ("lang", "en-us"),
      ("order", order.rawValue),
    ]
    for _ in 0..<query.children { params.append(("age", "10")) }
    return HTTP.url("https://www.booking.com/searchresults.html", params)
  }

  static let readyScript = """
  (() => {
    const t = document.body ? document.body.innerText : '';
    return document.querySelectorAll('[data-testid="property-card"]').length > 0
      || /No properties found|0 properties found/i.test(t)
      || /Just a moment|are you a robot|verify you are human/i.test(document.title + ' ' + t.slice(0, 600));
  })()
  """

  static let extractScript = """
  (() => {
    const body = document.body ? document.body.innerText : '';
    const cards = Array.from(document.querySelectorAll('[data-testid="property-card"]')).map(c => {
      const q = s => c.querySelector(s);
      const t = s => { const e = q(s); return e ? e.innerText : null; };
      const stars = q('[aria-label*="out of 5"]');
      const img = q('img');
      const link = q('a[data-testid="title-link"]') || q('a[href*="/hotel/"]') || q('a');
      return {
        name: t('[data-testid="title"]'),
        link: link ? link.href : null,
        price: t('[data-testid="price-and-discounted-price"]'),
        taxes: t('[data-testid="taxes-and-charges"]'),
        review: t('[data-testid="review-score"]'),
        stars: stars ? stars.getAttribute('aria-label') : null,
        image: img ? img.src : null,
        text: c.innerText || ''
      };
    });
    const blocked = cards.length === 0 && /Just a moment|are you a robot|verify you are human/i.test(document.title + ' ' + body.slice(0, 600));
    return JSON.stringify({ items: cards, captcha: blocked, consent: false });
  })()
  """

  @MainActor
  static func hotels(_ query: SearchQuery, order: Order) async throws -> SerpApi.HotelPage {
    let url = url(for: query, order: order)
    let json = try await WebPageReader.shared.read(url, ready: readyScript, extract: extractScript)
    return parsePage(json, query: query, url: url)
  }

  static func parsePage(_ json: JSONValue, query: SearchQuery, url: URL) -> SerpApi.HotelPage {
    var page = SerpApi.HotelPage()
    page.googleURL = url
    let nights = query.nights
    for card in json["items"].array {
      guard let name = card["name"].string, var total = Rx.number(card["price"].string) else { continue }
      // "+US$62 taxes and charges" is extra; "Includes taxes and charges" isn't.
      if let taxes = card["taxes"].string, taxes.contains("+"), let extra = Rx.number(taxes) { total += extra }
      let link = card["link"].url
      let text = Rx.normalizeSpaces(card["text"].string ?? "")
      let reviewText = Rx.normalizeSpaces(card["review"].string ?? "")
      let score = Rx.match(#"(\d{1,2}(?:\.\d)?)"#, reviewText)?[1].flatMap { Double($0) }
      let reviews = Rx.match(#"([\d,]+) reviews?"#, reviewText)?[1].flatMap { Int($0.replacingOccurrences(of: ",", with: "")) }
      let stars = Rx.match(#"(\d)"#, card["stars"].string ?? "")?[1].flatMap { Int($0) }
      let freeCancellation = text.range(of: "Free cancellation", options: .caseInsensitive) != nil
      var hotel = HotelOffer(
        id: "bk-" + (link?.path ?? name.lowercased()),
        name: name,
        kind: text.range(of: "Entire ", options: .caseInsensitive) != nil ? "Vacation rental" : "Hotel",
        stars: stars,
        rating: score.flatMap { $0 <= 10 ? $0 / 2 : nil },
        reviews: reviews,
        total: total,
        nightly: total / Double(max(1, nights)),
        currency: query.currency.uppercased(),
        nights: nights,
        checkIn: query.departDate,
        checkOut: query.checkOut,
        images: [card["image"].url].compactMap { $0 },
        website: link,
        sources: [HotelSourcePrice(source: "Booking.com", total: total, nightly: total / Double(max(1, nights)),
                                   url: link, freeCancellation: freeCancellation)],
        googleURL: url)
      if freeCancellation { hotel.tags.insert(.freeCancellation) }
      if hotel.kind == "Vacation rental" { hotel.tags.insert(.vacationRental) }
      page.hotels.append(hotel)
    }
    return page
  }
}
