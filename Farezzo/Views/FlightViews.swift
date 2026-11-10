import SwiftUI

struct FlightRow: View {
  let offer: FlightOffer
  let travelers: Int

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      AirlineLogo(url: offer.outbound.logo)
      VStack(alignment: .leading, spacing: 5) {
        LegLine(leg: offer.outbound)
        if let inbound = offer.inbound {
          LegLine(leg: inbound)
        } else if offer.isRoundTrip {
          Text(offer.serpReturnToken != nil ? "Return: choose on the next screen" : "Return: pick on Google Flights")
            .font(.caption).foregroundStyle(.secondary)
        }
        Text(airlinesText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        TagRow(tags: offer.tags)
      }
      Spacer(minLength: 4)
      VStack(alignment: .trailing, spacing: 2) {
        Text(Fmt.money(offer.price, offer.currency)).font(.headline).monospacedDigit()
        Text(offer.isRoundTrip ? "round trip" : "one way").font(.caption2).foregroundStyle(.secondary)
        if travelers > 1 {
          Text("\(travelers) travelers").font(.caption2).foregroundStyle(.secondary)
        }
      }
    }
    .padding(.vertical, 4)
  }

  private var airlinesText: String {
    var airlines = offer.outbound.airlines
    for airline in offer.inbound?.airlines ?? [] where !airlines.contains(airline) { airlines.append(airline) }
    return airlines.joined(separator: ", ") + " · " + offer.providers.map(\.rawValue).joined(separator: ", ")
  }
}

/// "08:05 JFK → 20:30⁺¹ LHR · 7h 25m · Nonstop"
struct LegLine: View {
  let leg: FlightLeg

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      HStack(spacing: 4) {
        Text(time(leg.departs)).font(.subheadline.weight(.semibold)).monospacedDigit()
        Text(leg.fromCode).font(.caption.monospaced()).foregroundStyle(.secondary)
        Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
        Text(time(leg.arrives)).font(.subheadline.weight(.semibold)).monospacedDigit()
        if dayShift > 0 {
          Text("+\(dayShift)").font(.caption2.weight(.bold)).foregroundStyle(.orange).baselineOffset(6)
        }
        Text(leg.toCode).font(.caption.monospaced()).foregroundStyle(.secondary)
      }
      Text("\(departDay) · \(leg.durationMinutes > 0 ? Fmt.duration(leg.durationMinutes) : "–") · \(leg.stopsText)")
        .font(.caption)
        .foregroundStyle(leg.stops == 0 ? Color.green : Color.secondary)
    }
  }

  private func time(_ date: Date?) -> String { date.map { Fmt.time.string(from: $0) } ?? "–" }
  private var departDay: String { leg.departs.map { Fmt.naiveDayShort.string(from: $0) } ?? "" }
  private var dayShift: Int {
    guard let departs = leg.departs, let arrives = leg.arrives else { return 0 }
    let calendar = Fmt.utcCalendar
    return calendar.dateComponents([.day], from: calendar.startOfDay(for: departs), to: calendar.startOfDay(for: arrives)).day ?? 0
  }
}

struct FlightDetail: View {
  let offer: FlightOffer
  let query: SearchQuery

  @State private var returns: [FlightOffer] = []
  @State private var chosenReturn: FlightOffer?
  @State private var loadingReturns = false
  @State private var error: String?

  private var current: FlightOffer { chosenReturn ?? offer }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      header

      LegCard(title: "Outbound", leg: current.outbound)
      if let inbound = current.inbound {
        LegCard(title: "Return", leg: inbound)
      } else if offer.serpReturnToken != nil {
        returnChooser
      } else if current.isRoundTrip {
        SectionCard("Return flight") {
          Text("The price is the lowest round trip with this outbound flight. Open Google Flights below, select this flight, and pick your return there.")
            .font(.callout).foregroundStyle(.secondary)
        }
      }

      if !current.notes.isEmpty {
        SectionCard("Good to know") {
          ForEach(current.notes, id: \.self) { note in
            Label(note, systemImage: "info.circle").font(.callout)
          }
        }
      }

      if current.parts.isEmpty {
        BookingSection(offer: current, query: query, title: "Book")
      } else {
        ForEach(Array(current.parts.enumerated()), id: \.offset) { index, part in
          BookingSection(offer: part, query: query,
                         title: "Ticket \(index + 1): \(part.outbound.fromCode) → \(part.outbound.toCode) · \(Fmt.money(part.price, part.currency))")
        }
      }
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline) {
        Text(Fmt.money(current.price, current.currency)).font(.largeTitle.bold()).monospacedDigit()
        Text(current.isRoundTrip ? "round trip" : "one way").foregroundStyle(.secondary)
        Spacer()
      }
      if query.travelers > 1 {
        Text("Total for \(query.travelers) travelers · \(Fmt.money(current.price / Double(query.travelers), current.currency)) each")
          .font(.subheadline).foregroundStyle(.secondary)
      }
      TagRow(tags: current.tags)
      Text("Found on " + current.providers.map(\.rawValue).joined(separator: ", "))
        .font(.caption).foregroundStyle(.secondary)
    }
  }

  private var returnChooser: some View {
    SectionCard("Return flight") {
      if returns.isEmpty {
        Text("The price shown is the lowest round trip with this outbound flight. Choose the return to see where to book.")
          .font(.callout).foregroundStyle(.secondary)
        Button {
          Task { await loadReturns() }
        } label: {
          HStack {
            if loadingReturns { ProgressView() }
            Text(loadingReturns ? "Loading return flights…" : "Show return flights")
          }
        }
        .buttonStyle(.bordered)
        .disabled(loadingReturns)
      } else {
        ForEach(returns) { option in
          Button {
            chosenReturn = option
          } label: {
            HStack {
              AirlineLogo(url: option.inbound?.logo, size: 24)
              if let leg = option.inbound { LegLine(leg: leg) }
              Spacer()
              Text(Fmt.money(option.price, option.currency)).font(.subheadline.weight(.semibold)).monospacedDigit()
            }
            .padding(8)
            .background(chosenReturn?.id == option.id ? Color.accentColor.opacity(0.14) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 10))
          }
          .buttonStyle(.plain)
        }
      }
      if let error { Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
    }
  }

  private func loadReturns() async {
    guard let key = APIKeys.load().serpApi else { error = "Add a SerpApi key in Settings."; return }
    loadingReturns = true
    defer { loadingReturns = false }
    do {
      returns = try await SerpApi(key: key).returnFlights(for: offer).sorted { $0.price < $1.price }
      if returns.isEmpty { error = "No return flights found for this outbound flight." }
      chosenReturn = returns.first
    } catch {
      self.error = error.localizedDescription
    }
  }
}

struct LegCard: View {
  let title: String
  let leg: FlightLeg

  var body: some View {
    SectionCard {
      HStack {
        Text(title).font(.headline)
        Spacer()
        Text("\(Fmt.duration(leg.durationMinutes)) · \(leg.stopsText)").font(.subheadline).foregroundStyle(.secondary)
      }
      ForEach(Array(leg.segments.enumerated()), id: \.offset) { index, segment in
        HStack(alignment: .top, spacing: 10) {
          AirlineLogo(url: segment.logo, size: 26)
          VStack(alignment: .leading, spacing: 3) {
            Text("\(Fmt.time.string(from: segment.departs))  \(segment.fromName) (\(segment.fromCode))")
              .font(.subheadline.weight(.medium))
            Text("\(segment.airline) \(segment.flightNumber)\(segment.aircraft.map { " · \($0)" } ?? "") · \(Fmt.duration(segment.durationMinutes))")
              .font(.caption).foregroundStyle(.secondary)
            Text("\(Fmt.time.string(from: segment.arrives))  \(segment.toName) (\(segment.toCode))")
              .font(.subheadline.weight(.medium))
            if segment.overnight {
              Label("Overnight flight", systemImage: "moon.stars").font(.caption).foregroundStyle(.indigo)
            }
          }
        }
        if index < leg.layovers.count && leg.unlistedStops == 0 {
          let layover = leg.layovers[index]
          Label("\(Fmt.duration(layover.minutes)) layover in \(layover.name.isEmpty ? layover.code : layover.name)\(layover.overnight ? " · overnight" : "")",
                systemImage: "clock")
            .font(.caption)
            .foregroundStyle(layover.minutes < 60 || layover.minutes > 360 ? Color.orange : Color.secondary)
            .padding(.leading, 36)
        }
      }
      if leg.unlistedStops > 0 {
        if leg.layovers.isEmpty {
          Label("\(leg.unlistedStops) connection\(leg.unlistedStops == 1 ? "" : "s") (airports not listed)", systemImage: "arrow.triangle.branch")
            .font(.caption).foregroundStyle(.secondary)
        } else {
          ForEach(Array(leg.layovers.enumerated()), id: \.offset) { _, layover in
            Label("\(Fmt.duration(layover.minutes)) layover at \(layover.name)\(layover.overnight ? " · overnight" : "")", systemImage: "clock")
              .font(.caption)
              .foregroundStyle(layover.minutes < 60 || layover.minutes > 360 ? Color.orange : Color.secondary)
          }
        }
      }
      if let departs = leg.departs {
        Text(Fmt.naiveDayShort.string(from: departs) + " · times are local").font(.caption2).foregroundStyle(.tertiary)
      }
    }
  }
}

/// Where to book: the sellers Google Flights lists for these exact flights (with prices), and
/// the provider's own links.
struct BookingSection: View {
  let offer: FlightOffer
  let query: SearchQuery
  let title: String

  @State private var links: [BookingLink] = []
  @State private var loading = false
  @State private var error: String?
  @State private var web: BookingLink?
  @Environment(\.openURL) private var openURL

  var body: some View {
    SectionCard(title) {
      if offer.serpBookingToken != nil {
        if links.isEmpty {
          Button {
            Task { await loadLinks() }
          } label: {
            HStack {
              if loading { ProgressView() }
              Label(loading ? "Comparing sellers…" : "Compare every seller's price", systemImage: "list.number")
            }
          }
          .buttonStyle(.borderedProminent)
          .disabled(loading)
        }
        ForEach(links) { link in
          linkRow(link, highlight: link.id == links.first?.id)
        }
      }
      ForEach(offer.bookings) { link in linkRow(link, highlight: false) }
      if !offer.bookings.contains(where: { $0.label.contains("Google Flights") }) {
        linkRow(BookingLink(label: "Open on Google Flights",
                            url: SerpApi.googleFlightsURL(from: offer.outbound.fromCode, to: offer.outbound.toCode,
                                                          depart: offer.outbound.departs.flatMap(Fmt.day(ofNaive:)) ?? offer.departDate,
                                                          ret: offer.inbound?.departs.flatMap(Fmt.day(ofNaive:)) ?? offer.returnDate)),
                highlight: false)
      }
      if let error { Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
    }
    .sheet(item: $web) { BookingSheet(link: $0) }
  }

  private func linkRow(_ link: BookingLink, highlight: Bool) -> some View {
    Button {
      if link.postBody != nil { web = link } else { openURL(link.url) }
    } label: {
      HStack {
        Image(systemName: highlight ? "checkmark.seal.fill" : "arrow.up.right.square")
          .foregroundStyle(highlight ? Color.green : Color.accentColor)
        Text(link.label).foregroundStyle(.primary)
        Spacer()
        if let price = link.price {
          Text(Fmt.money(price, offer.currency)).font(.subheadline.weight(.semibold)).monospacedDigit()
            .foregroundStyle(highlight ? Color.green : Color.primary)
        }
      }
      .padding(.vertical, 4)
    }
    .buttonStyle(.plain)
  }

  private func loadLinks() async {
    guard let key = APIKeys.load().serpApi, let token = offer.serpBookingToken, let params = offer.serpParams else { return }
    loading = true
    defer { loading = false }
    do {
      links = try await SerpApi(key: key).bookingOptions(params: params, token: token)
      if links.isEmpty { error = "No sellers listed; try Google Flights below." }
    } catch {
      self.error = error.localizedDescription
    }
  }
}
