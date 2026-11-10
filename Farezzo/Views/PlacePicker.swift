import SwiftUI

struct PlacePicker: View {
  let title: String
  let onPick: (Place) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var text = ""
  @State private var results: [Place] = []
  @State private var loading = false
  @State private var error: String?
  @AppStorage("recentPlaces") private var recentData = Data()

  private var recent: [Place] { (try? JSONDecoder().decode([Place].self, from: recentData)) ?? [] }
  private var term: String { text.trimmingCharacters(in: .whitespaces) }

  var body: some View {
    NavigationStack {
      List {
        if term.isEmpty {
          if !recent.isEmpty {
            Section("Recent") { ForEach(recent) { row($0) } }
          }
          Section("Popular") { ForEach(Airports.popular) { row($0) } }
        } else {
          if loading && results.isEmpty {
            HStack { ProgressView(); Text("Searching…").foregroundStyle(.secondary) }
          }
          if let error {
            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
          }
          ForEach(results) { row($0) }
          if term.count == 3 {
            Button {
              pick(Place(code: term.uppercased(), name: term.uppercased(), kind: .airport))
            } label: {
              Label("Use code \(term.uppercased())", systemImage: "character.cursor.ibeam")
            }
          }
        }
      }
      .searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: "City, airport or code")
      .autocorrectionDisabled()
      .task(id: term) { await lookUp() }
      .navigationTitle(title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
      }
    }
  }

  private func row(_ place: Place) -> some View {
    Button { pick(place) } label: {
      HStack(spacing: 12) {
        Image(systemName: place.kind == .city ? "building.2" : "airplane")
          .frame(width: 28)
          .foregroundStyle(.tint)
        VStack(alignment: .leading, spacing: 2) {
          Text(place.title).foregroundStyle(.primary)
          Text(place.subtitle).font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Text(place.code).font(.callout.monospaced().weight(.semibold)).foregroundStyle(.secondary)
      }
    }
  }

  private func lookUp() async {
    guard term.count >= 2 else { results = []; error = nil; return }
    try? await Task.sleep(for: .milliseconds(250))
    guard !Task.isCancelled else { return }
    loading = true
    defer { loading = false }
    do {
      let found = try await Travelpayouts.autocomplete(term)
      guard !Task.isCancelled else { return }
      results = found
      error = found.isEmpty ? "No matches" : nil
    } catch {
      guard !Task.isCancelled else { return }
      self.error = "Couldn't search places: \(error.localizedDescription)"
    }
  }

  private func pick(_ place: Place) {
    var list = recent.filter { $0.id != place.id }
    list.insert(place, at: 0)
    if let data = try? JSONEncoder().encode(Array(list.prefix(8))) { recentData = data }
    onPick(place)
    dismiss()
  }
}
