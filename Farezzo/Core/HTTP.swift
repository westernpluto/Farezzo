import Foundation

enum ProviderError: LocalizedError {
  case http(Int, String)
  case message(String)
  case missingKey(String)

  var errorDescription: String? {
    switch self {
    case .http(let code, let body): return "HTTP \(code): \(body)"
    case .message(let text): return text
    case .missingKey(let name): return "Add your \(name) key in Settings."
    }
  }
}

enum HTTP {
  static let session: URLSession = {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 75
    config.timeoutIntervalForResource = 120
    config.httpAdditionalHeaders = ["Accept": "application/json"]
    return URLSession(configuration: config)
  }()

  /// Sends the request and decodes the body as JSON. Error statuses still return their JSON body
  /// (providers explain failures there); only a non-JSON error body throws here.
  static func send(_ request: URLRequest) async throws -> (json: JSONValue, status: Int) {
    let (data, response) = try await session.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    let json = (try? JSONValue(data: data)) ?? JSONValue(nil)
    if json.isNull && !(200..<300).contains(status) {
      throw ProviderError.http(status, String(decoding: data.prefix(300), as: UTF8.self))
    }
    return (json, status)
  }

  static func get(_ url: URL, headers: [String: String] = [:]) async throws -> (json: JSONValue, status: Int) {
    var request = URLRequest(url: url)
    headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
    return try await send(request)
  }

  static func postJSON(_ url: URL, body: [String: Any], headers: [String: String] = [:]) async throws -> (json: JSONValue, status: Int) {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
    return try await send(request)
  }

  static func url(_ base: String, _ params: [(String, String)]) -> URL {
    var components = URLComponents(string: base)!
    components.queryItems = params.map { URLQueryItem(name: $0.0, value: $0.1) }
    return components.url!
  }
}
