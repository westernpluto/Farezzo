import SwiftUI

enum ResultItem: Hashable, Identifiable {
  case flight(FlightOffer)
  case hotel(HotelOffer)
  case package(PackageDeal)

  var id: String {
    switch self {
    case .flight(let offer): return "f-" + offer.id
    case .hotel(let hotel): return "h-" + hotel.id
    case .package(let deal): return "p-" + deal.id
    }
  }
}

enum ResultTab: String, CaseIterable, Identifiable {
  case packages = "Packages", flights = "Flights", hotels = "Hotels"
  var id: String { rawValue }
}

enum FlightSort: String, CaseIterable, Identifiable {
  case price = "Lowest price", value = "Best value", duration = "Shortest", departure = "Earliest departure"
  var id: String { rawValue }
}

enum HotelSort: String, CaseIterable, Identifiable {
  case price = "Lowest price", value = "Best value", rating = "Guest rating", stars = "Hotel class"
  var id: String { rawValue }
}

struct ResultsView: View {
  let session: SearchSession
  @State private var tab: ResultTab
  @State private var selection: ResultItem?
  @State private var flightSort: FlightSort = .price
  @State private var hotelSort: HotelSort = .price
  @State private var nonstopOnly = false
  @State private var hideCached = false
  @Environment(WatchStore.self) private var watches

  init(session: SearchSession) {
    self.session = session
    switch session.query.mode {
    case .flights: _tab = State(initialValue: .flights)
    case .hotels: _tab = State(initialValue: .hotels)
    case .package: _tab = State(initialValue: .packages)
    }
  }

  var body: some View {
    FoldAwareSplit { wide in
      listColumn(wide: wide)
    } detail: {
      detailColumn
    }
    .navigationTitle(session.query.summary)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar { toolbar }
    .onAppear {
      session.startIfNeeded()
      if selection == nil && session.phase == .done { selection = items.first }
    }
    .onChange(of: session.phase) { _, phase in
      if phase == .done { selection = items.first }
    }
  }

  // MARK: List

  private func listColumn(wide: Bool) -> some View {
    List {
      Section {
        ResultsHeader(session: session)
      }
      if session.query.mode == .package {
        Section {
          Picker("Show", selection: $tab) {
            ForEach(ResultTab.allCases) { Text($0.rawValue).tag($0) }
          }
          .pickerStyle(.segmented)
          .listRowBackground(Color.clear)
          .listRowInsets(EdgeInsets())
        }
      }
      Section {
        ForEach(items) { item in
          if wide {
            Button { selection = item } label: { ResultRow(item: item, query: session.query) }
              .buttonStyle(.plain)
              .listRowBackground(selection?.id == item.id ? Color.accentColor.opacity(0.14) : nil)
          } else {
            NavigationLink(value: DetailRoute(item: item, query: session.query)) { ResultRow(item: item, query: session.query) }
          }
        }
      } header: {
        if !items.isEmpty { Text(listTitle) }
      }
      if session.phase == .done && items.isEmpty {
        ContentUnavailableView {
          Label("No prices found", systemImage: "magnifyingglass")
        } description: {
          Text(session.warnings.first ?? "Try other dates, nearby airports or fewer filters.")
        }
      }
    }
    .listStyle(.insetGrouped)
    .refreshable { await session.run() }
  }

  @ViewBuilder private var detailColumn: some View {
    if let selection {
      ResultDetail(item: selection, query: session.query, embedded: true)
        .id(selection.id)
    } else if session.phase == .searching {
      ProgressView("Hunting for deals…")
    } else {
      ContentUnavailableView("Choose a result", systemImage: "hand.tap", description: Text("Its details and where to book appear here."))
    }
  }

  private var listTitle: String {
    switch tab {
    case .flights: return "\(filteredFlights.count) flights · \(flightSort.rawValue)"
    case .hotels: return "\(sortedHotels.count) places · \(hotelSort.rawValue)"
    case .packages: return "\(session.packages.count) combinations · lowest total"
    }
  }

  // MARK: Items

  private var items: [ResultItem] {
    switch tab {
    case .flights: return filteredFlights.map(ResultItem.flight)
    case .hotels: return sortedHotels.map(ResultItem.hotel)
    case .packages: return session.packages.map(ResultItem.package)
    }
  }

  private var filteredFlights: [FlightOffer] {
    var list = session.flights
    if nonstopOnly { list = list.filter { $0.maxStops == 0 } }
    if hideCached { list = list.filter { !$0.tags.contains(.cached) } }
    switch flightSort {
    case .price: return list
    case .value: return list.sorted { DealEngine.valueScore($0) < DealEngine.valueScore($1) }
    case .duration: return list.sorted { $0.totalMinutes < $1.totalMinutes }
    case .departure: return list.sorted { ($0.outbound.departs ?? .distantFuture) < ($1.outbound.departs ?? .distantFuture) }
    }
  }

  private var sortedHotels: [HotelOffer] {
    switch hotelSort {
    case .price: return session.hotels
    case .value: return session.hotels.sorted { $0.valueScore < $1.valueScore }
    case .rating: return session.hotels.sorted { ($0.rating ?? 0) > ($1.rating ?? 0) }
    case .stars: return session.hotels.sorted { ($0.stars ?? 0) > ($1.stars ?? 0) }
    }
  }

  // MARK: Toolbar

  @ToolbarContentBuilder private var toolbar: some ToolbarContent {
    ToolbarItem(placement: .primaryAction) {
      Menu {
        if tab == .flights {
          Picker("Sort", selection: $flightSort) {
            ForEach(FlightSort.allCases) { Text($0.rawValue).tag($0) }
          }
          Toggle("Nonstop only", isOn: $nonstopOnly)
          Toggle("Hide recent (cached) fares", isOn: $hideCached)
        } else if tab == .hotels {
          Picker("Sort", selection: $hotelSort) {
            ForEach(HotelSort.allCases) { Text($0.rawValue).tag($0) }
          }
        }
      } label: {
        Image(systemName: "line.3.horizontal.decrease.circle")
      }
      .disabled(tab == .packages)
    }
    ToolbarItem(placement: .primaryAction) {
      let watching = watches.isWatching(session.query)
      Button {
        watches.add(session.query, currentBest: session.bestPrice)
      } label: {
        Image(systemName: watching ? "bell.fill" : "bell")
      }
      .disabled(watching || session.phase != .done)
      .accessibilityLabel(watching ? "Watching this price" : "Watch this price")
    }
  }
}

// MARK: - Header

struct ResultsHeader: View {
  let session: SearchSession
  @State private var checking: CheckPage?

  struct CheckPage: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let url = session.humanCheck, session.phase == .done {
        VStack(alignment: .leading, spacing: 6) {
          Label("\(url.host?.replacingOccurrences(of: "www.", with: "") ?? "A site") wants to check you're human", systemImage: "person.badge.shield.checkmark")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.orange)
          Text("Some results are missing until you do. It's quick and only needed now and then.")
            .font(.caption).foregroundStyle(.secondary)
          Button("Continue on the site") { checking = CheckPage(url: url) }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
      }
      if session.phase == .searching {
        HStack(spacing: 10) {
          ProgressView()
          VStack(alignment: .leading) {
            Text("Hunting for deals…").font(.subheadline.weight(.semibold))
            Text(session.status.isEmpty ? "Starting" : session.status).font(.caption).foregroundStyle(.secondary)
          }
        }
      }
      if session.query.mode.needsFlights, let skyscanner = Skyscanner.url(for: session.query) {
        Link(destination: skyscanner) {
          Label("Compare this search on Skyscanner", systemImage: "arrow.up.right.square")
            .font(.subheadline)
        }
      }
      if let insights = session.insights {
        InsightBanner(insights: insights, currency: session.query.currency)
      }
      if !session.calendar.isEmpty && session.query.mode.needsFlights {
        FareCalendarStrip(calendar: session.calendar, selected: session.query.departDate, currency: session.query.currency) { day in
          Task { await session.rerun(departing: day) }
        }
      }
      if session.phase == .done {
        DisclosureGroup {
          VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(session.log.enumerated()), id: \.offset) { _, line in
              Label(line, systemImage: "checkmark.circle").font(.caption)
            }
            ForEach(Array(session.warnings.enumerated()), id: \.offset) { _, line in
              Label(line, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
          }
          .padding(.top, 4)
        } label: {
          Label("How Farezzo searched", systemImage: "sparkle.magnifyingglass").font(.subheadline)
        }
      }
    }
    .padding(.vertical, 4)
    .sheet(item: $checking) { page in
      HumanCheckSheet(url: page.url) { Task { await session.run() } }
    }
  }
}

struct InsightBanner: View {
  let insights: PriceInsights
  let currency: String

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: icon).font(.title2).foregroundStyle(color)
      VStack(alignment: .leading, spacing: 2) {
        Text(headline).font(.subheadline.weight(.semibold))
        if let low = insights.typicalLow, let high = insights.typicalHigh {
          Text("Usually \(Fmt.money(low, currency))–\(Fmt.money(high, currency)) on Google Flights")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
    }
  }

  private var level: String { insights.level?.lowercased() ?? "" }
  private var headline: String {
    switch level {
    case "low": return "Prices are low right now"
    case "high": return "Prices are higher than usual"
    default: return "Prices are typical"
    }
  }
  private var icon: String { level == "low" ? "arrow.down.circle.fill" : level == "high" ? "arrow.up.circle.fill" : "equal.circle.fill" }
  private var color: Color { level == "low" ? .green : level == "high" ? .red : .orange }
}

/// The month's cheapest recent fare for each departure day; tap a day to search it.
struct FareCalendarStrip: View {
  let calendar: [Date: Double]
  let selected: Date
  let currency: String
  let onPick: (Date) -> Void

  var body: some View {
    let days = calendar.keys.sorted()
    let prices = calendar.values.sorted()
    let low = prices.isEmpty ? 0 : prices[prices.count / 3]
    let high = prices.isEmpty ? 0 : prices[(prices.count * 2) / 3]
    VStack(alignment: .leading, spacing: 6) {
      Text("Cheapest days to leave").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
      ScrollViewReader { reader in
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 6) {
            ForEach(days, id: \.self) { day in
              let price = calendar[day] ?? 0
              let isSelected = Calendar.current.isDate(day, inSameDayAs: selected)
              Button { onPick(day) } label: {
                VStack(spacing: 2) {
                  Text(Fmt.weekday.string(from: day)).font(.caption2).foregroundStyle(.secondary)
                  Text(Fmt.dayNumber.string(from: day)).font(.callout.weight(.semibold))
                  Text(Fmt.money(price, currency)).font(.caption2.weight(.medium))
                    .foregroundStyle(price <= low ? .green : price >= high ? .red : .orange)
                }
                .frame(width: 58)
                .padding(.vertical, 6)
                .background(isSelected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
              }
              .buttonStyle(.plain)
              .id(day)
            }
          }
        }
        .onAppear {
          if let match = days.first(where: { Calendar.current.isDate($0, inSameDayAs: selected) }) {
            reader.scrollTo(match, anchor: .center)
          }
        }
      }
      Text("Recent fares per traveler from Aviasales; tap a day to search it live.")
        .font(.caption2).foregroundStyle(.tertiary)
    }
  }
}

// MARK: - Rows

struct ResultRow: View {
  let item: ResultItem
  let query: SearchQuery

  var body: some View {
    switch item {
    case .flight(let offer): FlightRow(offer: offer, travelers: query.travelers)
    case .hotel(let hotel): HotelRow(hotel: hotel)
    case .package(let deal): PackageRow(deal: deal)
    }
  }
}

struct ResultDetail: View {
  let item: ResultItem
  let query: SearchQuery
  /// Shown beside the list (two columns): the results screen keeps its own title.
  var embedded = false

  var body: some View {
    ScrollView {
      Group {
        switch item {
        case .flight(let offer): FlightDetail(offer: offer, query: query)
        case .hotel(let hotel): HotelDetail(hotel: hotel)
        case .package(let deal): PackageDetail(deal: deal, query: query)
        }
      }
      .padding()
      .frame(maxWidth: 760)
      .frame(maxWidth: .infinity)
    }
    .modifier(DetailTitle(title: embedded ? nil : title))
  }

  private var title: String {
    switch item {
    case .flight(let offer): return "\(offer.outbound.fromCode) → \(offer.outbound.toCode)"
    case .hotel(let hotel): return hotel.name
    case .package: return "Flight + Hotel"
    }
  }
}

private struct DetailTitle: ViewModifier {
  let title: String?
  @ViewBuilder func body(content: Content) -> some View {
    if let title {
      content.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
    } else {
      content
    }
  }
}
