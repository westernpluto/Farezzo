import Charts
import SwiftUI

struct WatchlistView: View {
  @Environment(WatchStore.self) private var store

  var body: some View {
    List {
      if store.items.isEmpty {
        ContentUnavailableView {
          Label("No price watches", systemImage: "bell")
        } description: {
          Text("Tap the bell on any search's results. Farezzo re-checks it in the background and tells you when the price drops.")
        }
      }
      ForEach(store.items) { item in
        NavigationLink(value: WatchRoute(id: item.id)) {
          WatchRow(item: item, refreshing: store.refreshing.contains(item.id))
        }
      }
      .onDelete { offsets in store.remove(offsets.map { store.items[$0].id }) }
    }
    .navigationTitle("Watching")
    .toolbar {
      if !store.items.isEmpty {
        Button {
          Task { await store.refreshAll(light: false) }
        } label: {
          Label("Check all now", systemImage: "arrow.clockwise")
        }
        .disabled(!store.refreshing.isEmpty)
      }
    }
    .refreshable { await store.refreshAll(light: false) }
  }
}

struct WatchRow: View {
  let item: WatchedSearch
  let refreshing: Bool

  var body: some View {
    HStack {
      Image(systemName: item.query.mode.icon).foregroundStyle(.tint).frame(width: 26)
      VStack(alignment: .leading, spacing: 3) {
        Text(item.query.summary).font(.subheadline.weight(.semibold)).lineLimit(1)
        if let checked = item.lastChecked {
          Text("Checked \(checked.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
        }
        if let error = item.lastError { Text(error).font(.caption).foregroundStyle(.orange).lineLimit(1) }
      }
      Spacer()
      if refreshing {
        ProgressView()
      } else if let latest = item.latest {
        VStack(alignment: .trailing, spacing: 2) {
          Text(Fmt.money(latest, item.query.currency)).font(.headline).monospacedDigit()
          if let change = item.change, abs(change) >= 0.005 {
            Text("\(change < 0 ? "▼" : "▲") \(abs(change).formatted(.percent.precision(.fractionLength(0))))")
              .font(.caption2.weight(.bold))
              .foregroundStyle(change < 0 ? Color.green : Color.red)
          }
        }
      }
    }
  }
}

struct WatchDetail: View {
  let id: UUID
  @Environment(WatchStore.self) private var store
  @State private var targetText = ""

  private var item: WatchedSearch? { store.items.first { $0.id == id } }

  var body: some View {
    if let item {
      List {
        Section {
          if item.history.count >= 2 {
            Chart(item.history) { point in
              LineMark(x: .value("Checked", point.date), y: .value("Price", point.price))
                .interpolationMethod(.monotone)
              PointMark(x: .value("Checked", point.date), y: .value("Price", point.price))
              if let target = item.targetPrice {
                RuleMark(y: .value("Target", target))
                  .foregroundStyle(.green)
                  .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
              }
            }
            .frame(height: 180)
          } else {
            Text("The price history fills in as Farezzo re-checks this search.").foregroundStyle(.secondary)
          }
          if let latest = item.latest { LabeledContent("Latest", value: Fmt.money(latest, item.query.currency)) }
          if let lowest = item.lowest { LabeledContent("Lowest seen", value: Fmt.money(lowest, item.query.currency)) }
        }
        Section {
          TextField("Alert me at or under…", text: $targetText)
            .keyboardType(.decimalPad)
            .onSubmit(saveTarget)
          Button("Save target", action: saveTarget)
        } header: {
          Text("Target price")
        } footer: {
          Text("You'll also get a notification whenever the price drops 5% or more.")
        }
        Section {
          Button {
            Task { await store.refresh(id, light: false) }
          } label: {
            Label(store.refreshing.contains(id) ? "Checking…" : "Check now", systemImage: "arrow.clockwise")
          }
          .disabled(store.refreshing.contains(id))
          NavigationLink(value: ResultsRoute(query: item.query)) {
            Label("See all deals", systemImage: "list.bullet")
          }
        }
      }
      .navigationTitle(item.query.summary)
      .navigationBarTitleDisplayMode(.inline)
      .onAppear {
        if let target = item.targetPrice { targetText = String(Int(target)) }
      }
    } else {
      ContentUnavailableView("Watch removed", systemImage: "bell.slash")
    }
  }

  private func saveTarget() {
    let value = Double(targetText.filter { "0123456789.".contains($0) })
    store.setTarget(id, value)
  }
}
