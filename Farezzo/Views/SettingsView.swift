import SwiftUI

struct SettingsView: View {
  @State private var serpApi = Keychain.get(APIKeys.serpAccount) ?? ""
  @State private var duffel = Keychain.get(APIKeys.duffelAccount) ?? ""
  @State private var travelpayouts = Keychain.get(APIKeys.travelpayoutsAccount) ?? ""
  @State private var serpStatus: String?
  @State private var checking = false
  @AppStorage(APIKeys.webModeDefaultsKey) private var webMode = true
  @AppStorage("currency") private var currency = Locale.current.currency?.identifier ?? "USD"
  @AppStorage("region") private var region = (Locale.current.region?.identifier ?? "US").lowercased()

  private static let currencies = ["USD", "EUR", "GBP", "CAD", "AUD", "JPY", "MXN", "INR", "BRL", "CHF", "SEK", "NOK",
                                   "DKK", "NZD", "SGD", "HKD", "KRW", "CNY", "AED", "THB", "TRY", "ZAR", "PLN"]

  var body: some View {
    Form {
      Section {
        Toggle(isOn: $webMode) {
          Label("No-key mode", systemImage: "key.slash")
        }
      } header: {
        Text("No sign-up needed")
      } footer: {
        Text("Without a SerpApi key, Farezzo reads Google Flights and Booking.com's own pages on this iPhone, like a browser. It needs no account, but now and then a site may ask you to confirm you're human, and a site redesign can break it until the app is updated. It also skips the other-regions check, which needs SerpApi's servers abroad. Reading pages this way isn't allowed by those sites' terms of use.")
      }

      Section {
        keyField("SerpApi key", text: $serpApi, account: APIKeys.serpAccount)
        if let serpStatus { Text(serpStatus).font(.caption).foregroundStyle(.secondary) }
        Button {
          Task { await checkSerp() }
        } label: {
          HStack { if checking { ProgressView() }; Text("Check searches left") }
        }
        .disabled(serpApi.isEmpty || checking)
        Link("Get a SerpApi key", destination: URL(string: "https://serpapi.com/users/sign_up")!)
      } header: {
        Text("Google Flights & Google Hotels (optional)")
      } footer: {
        Text("Optional: replaces no-key mode with SerpApi's servers, which are more dependable and add every booking site's hotel prices and other regions' fares. The widest source: almost every airline and booking site. Each search uses one search from your SerpApi plan (the free plan includes a monthly allowance).")
      }

      Section {
        keyField("Duffel access token", text: $duffel, account: APIKeys.duffelAccount)
        Link("Get a Duffel token", destination: URL(string: "https://app.duffel.com/join")!)
      } header: {
        Text("Airlines direct (optional, for businesses)")
      } footer: {
        Text("Live fares from airlines' own systems, including some not sold by travel agencies. Searching is free. Use a live token (duffel_live_…); test tokens only return a sample airline.")
      }

      Section {
        keyField("Travelpayouts API token", text: $travelpayouts, account: APIKeys.travelpayoutsAccount)
        Link("Get a Travelpayouts token", destination: URL(string: "https://www.travelpayouts.com/developers/api")!)
      } header: {
        Text("Fare calendar & budget fares (optional)")
      } footer: {
        Text("Free. Powers the cheapest-day calendar and adds recent low fares found on Aviasales, including low-cost airlines.")
      }

      Section("Prices") {
        Picker("Currency", selection: $currency) {
          ForEach(Self.currencies, id: \.self) { Text($0).tag($0) }
          if !Self.currencies.contains(currency) { Text(currency).tag(currency) }
        }
        Picker("Your region", selection: $region) {
          ForEach(Self.regions, id: \.self) { code in
            Text(Locale.current.localizedString(forRegionCode: code.uppercased()) ?? code.uppercased()).tag(code)
          }
          if !Self.regions.contains(region) { Text(region.uppercased()).tag(region) }
        }
      }

      Section("How Farezzo finds deals") {
        explainer("square.stack.3d.up", "Every source at once", "Google Flights, airlines' own systems and Aviasales are searched in parallel; the lowest price for each itinerary wins.")
        explainer("mappin.and.ellipse", "All & nearby airports", "Cities include every airport, plus alternatives nearby where low-cost airlines often fly.")
        explainer("calendar", "Flexible dates", "The free fare calendar finds the cheapest days around yours, and those are searched live.")
        explainer("ticket", "Split tickets", "Two one-way tickets, often on different airlines, are compared with round-trip fares.")
        explainer("globe", "Other regions", "Google Flights is also asked from other countries, where some sites sell the same flights for less.")
        explainer("list.bullet.rectangle", "Every booking site", "For the best hotels, every site's price is compared: Booking.com, Expedia, Hotels.com, Agoda, the hotel itself and more.")
        explainer("bell.badge", "Price watches", "Saved searches are re-checked in the background, with an alert when prices drop.")
      }

      Section {
        Text("Keys are stored in this iPhone's Keychain and only sent to their own provider.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .readableWidth()
    .navigationTitle("Settings")
  }

  private static let regions = ["us", "gb", "ca", "au", "de", "fr", "es", "it", "nl", "ie", "in", "jp", "kr", "mx",
                                "br", "ar", "sg", "hk", "ae", "th", "za", "nz", "se", "ch", "tr", "pl"]

  private func keyField(_ title: String, text: Binding<String>, account: String) -> some View {
    SecureField(title, text: text)
      .textInputAutocapitalization(.never)
      .autocorrectionDisabled()
      .onChange(of: text.wrappedValue) { _, value in Keychain.set(account, value) }
  }

  private func explainer(_ icon: String, _ title: String, _ text: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: icon).foregroundStyle(.tint).frame(width: 24)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.subheadline.weight(.semibold))
        Text(text).font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private func checkSerp() async {
    checking = true
    defer { checking = false }
    do {
      let account = try await SerpApi(key: serpApi.trimmingCharacters(in: .whitespacesAndNewlines)).account()
      var parts: [String] = []
      if let plan = account.plan { parts.append(plan) }
      if let left = account.left { parts.append("\(left) searches left") }
      serpStatus = parts.isEmpty ? "Key works." : "Key works · " + parts.joined(separator: " · ")
    } catch {
      serpStatus = "Couldn't check: \(error.localizedDescription)"
    }
  }
}
