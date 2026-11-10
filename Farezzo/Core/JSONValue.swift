import Foundation

/// A forgiving view over decoded JSON. Travel APIs add, drop and retype fields often, so
/// providers read what they need through this instead of strict `Codable` models: a missing or
/// oddly typed field becomes `nil` rather than failing the whole response.
struct JSONValue {
  let raw: Any?

  init(_ raw: Any?) {
    self.raw = (raw is NSNull) ? nil : raw
  }

  init(data: Data) throws {
    self.init(try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
  }

  subscript(key: String) -> JSONValue {
    JSONValue((raw as? [String: Any])?[key])
  }

  subscript(index: Int) -> JSONValue {
    guard let items = raw as? [Any], items.indices.contains(index) else { return JSONValue(nil) }
    return JSONValue(items[index])
  }

  var array: [JSONValue] { (raw as? [Any])?.map { JSONValue($0) } ?? [] }
  var object: [String: JSONValue] { (raw as? [String: Any])?.mapValues { JSONValue($0) } ?? [:] }

  var string: String? {
    if let text = raw as? String { return text.isEmpty ? nil : text }
    if let number = raw as? NSNumber { return number.stringValue }
    return nil
  }

  /// Numbers, or numbers inside text such as "$1,234".
  var double: Double? {
    if let number = raw as? NSNumber { return number.doubleValue }
    if let text = raw as? String {
      let cleaned = text.filter { "0123456789.-".contains($0) }
      return Double(cleaned)
    }
    return nil
  }

  var int: Int? { double.map { Int($0.rounded()) } }
  var bool: Bool? {
    if let number = raw as? NSNumber { return number.boolValue }
    if let text = raw as? String { return ["true", "1", "yes"].contains(text.lowercased()) }
    return nil
  }
  var url: URL? { string.flatMap { URL(string: $0) } }
  var isNull: Bool { raw == nil }
}
