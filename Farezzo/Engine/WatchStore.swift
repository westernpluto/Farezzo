import BackgroundTasks
import Foundation
import Observation
import UserNotifications

struct WatchedSearch: Codable, Identifiable, Hashable {
  var id = UUID()
  var query: SearchQuery
  var created = Date()
  var history: [PricePoint] = []
  var targetPrice: Double?
  var lastChecked: Date?
  var lastError: String?

  var latest: Double? { history.last?.price }
  var lowest: Double? { history.map(\.price).min() }
  /// Change since the first check, as a fraction (negative: cheaper).
  var change: Double? {
    guard let first = history.first?.price, let last = latest, first > 0 else { return nil }
    return (last - first) / first
  }
}

/// Saved searches whose best price is re-checked in the background, with a notification when
/// it drops (5% or more) or reaches the target.
@MainActor
@Observable
final class WatchStore {
  static let shared = WatchStore()
  nonisolated static let taskID = "com.farezzo.watch"

  var items: [WatchedSearch] = []
  var refreshing: Set<UUID> = []

  private var fileURL: URL {
    let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder.appendingPathComponent("watches.json")
  }

  init() {
    if let data = try? Data(contentsOf: fileURL),
       let saved = try? JSONDecoder().decode([WatchedSearch].self, from: data) {
      items = saved
    }
  }

  private func save() {
    if let data = try? JSONEncoder().encode(items) { try? data.write(to: fileURL, options: .atomic) }
  }

  func isWatching(_ query: SearchQuery) -> Bool { items.contains { $0.query == query } }

  func add(_ query: SearchQuery, currentBest: Double?) {
    guard !isWatching(query) else { return }
    var item = WatchedSearch(query: query)
    if let currentBest {
      item.history = [PricePoint(date: Date(), price: currentBest)]
      item.lastChecked = Date()
    }
    items.insert(item, at: 0)
    save()
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    Self.scheduleBackgroundRefresh()
  }

  func remove(_ ids: [UUID]) {
    items.removeAll { ids.contains($0.id) }
    save()
  }

  func setTarget(_ id: UUID, _ price: Double?) {
    guard let index = items.firstIndex(where: { $0.id == id }) else { return }
    items[index].targetPrice = price
    save()
  }

  /// Checks one watch. Background checks use a lighter search (no extra dates, regions or
  /// per-site hotel comparisons) to spare the SerpApi plan.
  func refresh(_ id: UUID, light: Bool) async {
    guard let index = items.firstIndex(where: { $0.id == id }), !refreshing.contains(id) else { return }
    refreshing.insert(id)
    defer { refreshing.remove(id) }
    var query = items[index].query
    if light {
      query.flexDays = 0
      query.checkOtherMarkets = false
      query.compareAllHotelSites = false
    }
    let session = SearchSession(query: query)
    await session.run()
    guard let i = items.firstIndex(where: { $0.id == id }) else { return }
    items[i].lastChecked = Date()
    if let price = session.bestPrice {
      let previous = items[i].latest
      items[i].history.append(PricePoint(date: Date(), price: price))
      items[i].history = Array(items[i].history.suffix(200))
      items[i].lastError = nil
      notifyIfCheaper(items[i], previous: previous, now: price)
    } else {
      items[i].lastError = session.warnings.first ?? "No prices found"
    }
    save()
  }

  func refreshAll(light: Bool) async {
    for item in items { await refresh(item.id, light: light) }
  }

  private func notifyIfCheaper(_ item: WatchedSearch, previous: Double?, now: Double) {
    let currency = item.query.currency
    var body: String?
    if let target = item.targetPrice, now <= target, (previous ?? .infinity) > target {
      body = "Now \(Fmt.money(now, currency)), at or under your \(Fmt.money(target, currency)) target."
    } else if let previous, now <= previous * 0.95 {
      body = "Dropped to \(Fmt.money(now, currency)) from \(Fmt.money(previous, currency))."
    }
    guard let body else { return }
    let content = UNMutableNotificationContent()
    content.title = "Price drop: \(item.query.summary)"
    content.body = body
    content.sound = .default
    UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: item.id.uuidString, content: content, trigger: nil))
  }

  // MARK: Background

  nonisolated static func scheduleBackgroundRefresh() {
    let request = BGAppRefreshTaskRequest(identifier: taskID)
    request.earliestBeginDate = Date(timeIntervalSinceNow: 4 * 3600)
    try? BGTaskScheduler.shared.submit(request)
  }

  static func runBackgroundRefresh() async {
    scheduleBackgroundRefresh()
    await shared.refreshAll(light: true)
  }
}
