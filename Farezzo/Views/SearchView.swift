import SwiftUI

struct ResultsRoute: Hashable {
  let id = UUID()
  let query: SearchQuery
}

enum SearchStore {
  private static let key = "lastQuery"
  static func load() -> SearchQuery {
    guard let data = UserDefaults.standard.data(forKey: key),
          var query = try? JSONDecoder().decode(SearchQuery.self, from: data) else {
      var query = SearchQuery()
      query.currency = UserDefaults.standard.string(forKey: "currency") ?? query.currency
      query.region = UserDefaults.standard.string(forKey: "region") ?? query.region
      return query
    }
    // Old dates roll forward to the same trip a few weeks out.
    if Calendar.current.startOfDay(for: query.departDate) < Calendar.current.startOfDay(for: Date()) {
      let length = query.returnDate.map { Fmt.days(from: query.departDate, to: $0) }
      query.departDate = Fmt.addDays(21, to: Date())
      query.returnDate = length.map { Fmt.addDays($0, to: query.departDate) }
    }
    query.currency = UserDefaults.standard.string(forKey: "currency") ?? query.currency
    query.region = UserDefaults.standard.string(forKey: "region") ?? query.region
    return query
  }

  static func save(_ query: SearchQuery) {
    if let data = try? JSONEncoder().encode(query) { UserDefaults.standard.set(data, forKey: key) }
  }
}

struct SearchView: View {
  enum Slot: String, Identifiable { case origin, destination; var id: String { rawValue } }

  @State private var query = SearchStore.load()
  @State private var picking: Slot?
  @State private var route: ResultsRoute?
  @State private var keys = APIKeys.load()
  @AppStorage("currency") private var currency = Locale.current.currency?.identifier ?? "USD"
  @AppStorage("region") private var region = (Locale.current.region?.identifier ?? "US").lowercased()

  var body: some View {
    Form {
      Section {
        Picker("Trip", selection: $query.mode) {
          ForEach(TripMode.allCases) { mode in
            Text(mode.title).tag(mode)
          }
        }
        .pickerStyle(.segmented)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
      }

      Section("Where") {
        if query.mode.needsFlights {
          placeRow(label: "From", place: query.origin, icon: "airplane.departure") { picking = .origin }
        }
        placeRow(label: query.mode == .hotels ? "Staying in" : "To", place: query.destination,
                 icon: query.mode == .hotels ? "bed.double" : "airplane.arrival") { picking = .destination }
        if query.mode.needsFlights {
          Button {
            (query.origin, query.destination) = (query.destination, query.origin)
          } label: {
            Label("Swap", systemImage: "arrow.up.arrow.down")
          }
          .disabled(query.origin == nil && query.destination == nil)
        }
      }

      Section("When") {
        if query.mode == .flights {
          Toggle("Round trip", isOn: roundTrip)
        }
        DatePicker(query.mode == .hotels ? "Check in" : "Depart", selection: $query.departDate,
                   in: Calendar.current.startOfDay(for: Date())..., displayedComponents: .date)
        if query.returnDate != nil {
          DatePicker(query.mode == .hotels ? "Check out" : "Return", selection: returnDate,
                     in: Fmt.addDays(1, to: query.departDate)..., displayedComponents: .date)
        }
        if query.mode.needsHotels {
          LabeledContent("Nights", value: "\(query.nights)")
        }
      }

      Section("Who") {
        Stepper("Adults: \(query.adults)", value: $query.adults, in: 1...9)
        Stepper("Children: \(query.children)", value: $query.children, in: 0...8)
        if query.mode.needsFlights {
          Picker("Cabin", selection: $query.cabin) {
            ForEach(Cabin.allCases) { Text($0.title).tag($0) }
          }
          Picker("Stops", selection: $query.maxStops) {
            Text("Any").tag(Int?.none)
            Text("Nonstop only").tag(Int?.some(0))
            Text("1 stop or fewer").tag(Int?.some(1))
            Text("2 stops or fewer").tag(Int?.some(2))
          }
        }
      }

      if query.mode.needsHotels {
        Section("Stay") {
          Picker("Hotel class", selection: $query.minStars) {
            Text("Any").tag(0)
            ForEach(2...5, id: \.self) { Text("\($0)★ and up").tag($0) }
          }
          Picker("Guest rating", selection: $query.minRating) {
            Text("Any").tag(0.0)
            Text("3.5 and up").tag(3.5)
            Text("4.0 and up").tag(4.0)
            Text("4.5 and up").tag(4.5)
          }
          Toggle("Free cancellation only", isOn: $query.freeCancellation)
          Toggle("Include vacation rentals", isOn: $query.includeVacationRentals)
        }
      }

      dealHunting

      Section {
        Button(action: search) {
          HStack {
            Spacer()
            Label("Find the best deals", systemImage: "sparkle.magnifyingglass").font(.headline)
            Spacer()
          }
          .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
        .disabled(!query.problems.isEmpty)
      } footer: {
        if let problem = query.problems.first { Text(problem) }
      }

      if !keys.hasAnyFlightSource {
        Section {
          NavigationLink {
            SettingsView()
          } label: {
            Label("Add your API keys to start searching", systemImage: "key.fill").foregroundStyle(.orange)
          }
        } footer: {
          Text("Farezzo gets prices from Google Flights & Hotels (SerpApi), airlines directly (Duffel) and Aviasales. Keys stay on this iPhone.")
        }
      }
    }
    .readableWidth()
    .navigationTitle("Farezzo")
    .sheet(item: $picking) { slot in
      PlacePicker(title: slot == .origin ? "Leaving from" : (query.mode == .hotels ? "Staying in" : "Going to")) { place in
        if slot == .origin { query.origin = place } else { query.destination = place }
      }
    }
    .navigationDestination(item: $route) { route in
      ResultsView(query: route.query)
    }
    .onChange(of: query) { _, newValue in SearchStore.save(newValue) }
    .onChange(of: query.mode) { _, mode in
      if mode.needsHotels && query.returnDate == nil { query.returnDate = Fmt.addDays(3, to: query.departDate) }
    }
    .onChange(of: query.departDate) { oldValue, newValue in
      // Keep the trip's length when the departure moves.
      if let returnDate = query.returnDate {
        let length = max(1, Fmt.days(from: oldValue, to: returnDate))
        query.returnDate = Fmt.addDays(length, to: newValue)
      }
    }
    .onAppear {
      keys = APIKeys.load()
      query.currency = currency
      query.region = region
    }
  }

  private var dealHunting: some View {
    Section {
      if query.mode.needsFlights {
        Toggle(isOn: $query.includeNearbyAirports) {
          Label("All & nearby airports", systemImage: "mappin.and.ellipse")
        }
        Stepper(value: $query.flexDays, in: 0...3) {
          Label(query.flexDays == 0 ? "Exact dates" : "Flexible ±\(query.flexDays) day\(query.flexDays == 1 ? "" : "s")",
                systemImage: "calendar")
        }
        if query.isRoundTrip {
          Toggle(isOn: $query.trySplitTickets) {
            Label("Try two one-way tickets", systemImage: "ticket")
          }
        }
        Toggle(isOn: $query.checkOtherMarkets) {
          Label("Compare other regions' prices", systemImage: "globe")
        }
      }
      if query.mode.needsHotels {
        Toggle(isOn: $query.compareAllHotelSites) {
          Label("Check every booking site", systemImage: "list.bullet.rectangle")
        }
      }
    } header: {
      Text("Deal hunting")
    } footer: {
      let searches = DealEngine.estimatedSerpSearches(query, keys: keys)
      if searches > 0 {
        Text("Uses about \(searches) SerpApi searches. Duffel and Aviasales searches are free.")
      } else {
        Text("Turn everything on to leave no deal unchecked.")
      }
    }
  }

  private var roundTrip: Binding<Bool> {
    Binding(
      get: { query.returnDate != nil },
      set: { query.returnDate = $0 ? Fmt.addDays(7, to: query.departDate) : nil })
  }

  private var returnDate: Binding<Date> {
    Binding(
      get: { query.returnDate ?? Fmt.addDays(1, to: query.departDate) },
      set: { query.returnDate = $0 })
  }

  private func placeRow(label: String, place: Place?, icon: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack {
        Image(systemName: icon).frame(width: 24).foregroundStyle(.tint)
        VStack(alignment: .leading, spacing: 2) {
          Text(label).font(.caption).foregroundStyle(.secondary)
          Text(place?.shortLabel ?? "Choose").foregroundStyle(place == nil ? Color.secondary : Color.primary)
        }
        Spacer()
        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
      }
    }
    .buttonStyle(.plain)
  }

  private func search() {
    query.currency = currency
    query.region = region
    route = ResultsRoute(query: query)
  }
}
