import Foundation

/// Currency conversion with the European Central Bank's daily rates (Frankfurter, no key).
/// Needed when a provider prices in the airline's currency rather than the one asked for.
actor FX {
  static let shared = FX()
  private var rates: [String: (fetched: Date, rates: [String: Double])] = [:]

  func convert(_ amount: Double, from: String, to: String) async -> Double? {
    let source = from.uppercased()
    let target = to.uppercased()
    if source == target { return amount }
    guard let table = await table(base: target), let rate = table[source], rate > 0 else { return nil }
    return amount / rate
  }

  private func table(base: String) async -> [String: Double]? {
    if let cached = rates[base], Date().timeIntervalSince(cached.fetched) < 6 * 3600 { return cached.rates }
    let endpoints = [
      HTTP.url("https://api.frankfurter.dev/v1/latest", [("base", base)]),
      HTTP.url("https://api.frankfurter.app/latest", [("from", base)]),
    ]
    for url in endpoints {
      guard let (json, status) = try? await HTTP.get(url), (200..<300).contains(status) else { continue }
      var table: [String: Double] = [:]
      for (code, value) in json["rates"].object {
        if let rate = value.double { table[code.uppercased()] = rate }
      }
      if !table.isEmpty {
        rates[base] = (Date(), table)
        return table
      }
    }
    return nil
  }
}
