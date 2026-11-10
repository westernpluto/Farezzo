import Foundation
import Security

/// API keys live in the Keychain (this device only), never in UserDefaults or the app bundle.
enum Keychain {
  private static let service = "com.farezzo.keys"

  static func get(_ account: String) -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
    let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }

  static func set(_ account: String, _ value: String?) {
    let base: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    SecItemDelete(base as CFDictionary)
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !trimmed.isEmpty else { return }
    var add = base
    add[kSecValueData as String] = Data(trimmed.utf8)
    add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    SecItemAdd(add as CFDictionary, nil)
  }
}

struct APIKeys: Sendable, Equatable {
  var serpApi: String?
  var duffel: String?
  var travelpayouts: String?
  /// No-key mode: read Google Flights and Booking.com's pages on the iPhone when there's no
  /// SerpApi key. On unless turned off in Settings.
  var webMode = true

  static let webModeDefaultsKey = "webMode"

  static let serpAccount = "serpapi"
  static let duffelAccount = "duffel"
  static let travelpayoutsAccount = "travelpayouts"

  static func load() -> APIKeys {
    APIKeys(
      serpApi: Keychain.get(serpAccount),
      duffel: Keychain.get(duffelAccount),
      travelpayouts: Keychain.get(travelpayoutsAccount),
      webMode: UserDefaults.standard.object(forKey: webModeDefaultsKey) as? Bool ?? true)
  }

  var usesWebMode: Bool { serpApi == nil && webMode }
  var hasAnyFlightSource: Bool { serpApi != nil || duffel != nil || travelpayouts != nil || webMode }
  var hasHotelSource: Bool { serpApi != nil || webMode }
  var sourceCount: Int { [serpApi, duffel, travelpayouts].compactMap { $0 }.count + (usesWebMode ? 1 : 0) }
}
