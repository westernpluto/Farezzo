import UIKit
import WebKit

enum WebReadError: LocalizedError {
  /// The site wants a person to confirm they're not a robot (or to accept cookies) first.
  case needsHuman(URL)
  case unreadable(String)

  var errorDescription: String? {
    switch self {
    case .needsHuman: return "The site asked to confirm you're human. Tap \"Continue on the site\" and search again."
    case .unreadable(let what): return "Couldn't read \(what). The site may have changed its page."
    }
  }
}

/// No-key mode: loads a public web page in a hidden browser on this iPhone, waits for it to
/// render, and runs a script that pulls the results out of the page, just as a person reading
/// it would see them. Pages load two at a time with short pauses so a search looks like normal
/// browsing. Cookies are shared with the visible sheet that lets the user pass a robot check.
@MainActor
final class WebPageReader: NSObject {
  static let shared = WebPageReader()

  static let userAgent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
  private let maxConcurrent = 2
  private var active = 0
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var preparedCookies = false

  private func acquire() async {
    if active < maxConcurrent {
      active += 1
      return
    }
    await withCheckedContinuation { waiters.append($0) }
  }

  private func release() {
    if waiters.isEmpty { active -= 1 } else { waiters.removeFirst().resume() }
  }

  /// Loads `url`, waits until `ready` (a script returning true/false) passes or `timeout`
  /// runs out, optionally runs `expand` (e.g. "show more results") and waits a moment, then
  /// returns what `extract` (a script returning a JSON string) finds.
  func read(_ url: URL, ready: String, extract: String, expand: String? = nil, timeout: TimeInterval = 25) async throws -> JSONValue {
    await acquire()
    defer { release() }
    await prepareCookies()
    try await Task.sleep(for: .milliseconds(Int.random(in: 300...1100)))

    let webView = Self.makeWebView()
    attach(webView)
    defer {
      webView.stopLoading()
      webView.removeFromSuperview()
    }
    webView.load(URLRequest(url: url))

    let start = Date()
    var isReady = false
    while Date().timeIntervalSince(start) < timeout {
      try await Task.sleep(for: .milliseconds(600))
      if let result = try? await webView.evaluateJavaScript(ready) as? Bool, result {
        isReady = true
        break
      }
    }
    if isReady {
      // Let the rest of the list render.
      try await Task.sleep(for: .milliseconds(1500))
      if let expand, (try? await webView.evaluateJavaScript(expand) as? Bool) == true {
        try await Task.sleep(for: .milliseconds(2500))
      }
    }
    guard let text = try await webView.evaluateJavaScript(extract) as? String else {
      throw WebReadError.unreadable(url.host ?? "the page")
    }
    let json = try JSONValue(data: Data(text.utf8))
    if json["captcha"].bool == true || json["consent"].bool == true {
      throw WebReadError.needsHuman(webView.url ?? url)
    }
    return json
  }

  static func makeWebView() -> WKWebView {
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .default()
    config.defaultWebpagePreferences.preferredContentMode = .desktop
    config.mediaTypesRequiringUserActionForPlayback = .all
    let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 2400), configuration: config)
    webView.customUserAgent = userAgent
    return webView
  }

  /// Off-screen but in a window, so the page runs its scripts at full speed.
  private func attach(_ webView: WKWebView) {
    let window = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
      .first { $0.isKeyWindow }
    guard let window else { return }
    webView.frame.origin = CGPoint(x: -4000, y: 0)
    webView.alpha = 0.01
    webView.isUserInteractionEnabled = false
    window.insertSubview(webView, at: 0)
  }

  /// Google's cookie-consent page (shown in some countries) would otherwise come first.
  private func prepareCookies() async {
    guard !preparedCookies else { return }
    preparedCookies = true
    let store = WKWebsiteDataStore.default().httpCookieStore
    let existing = await store.allCookies()
    guard !existing.contains(where: { $0.name == "SOCS" && $0.domain.hasSuffix("google.com") }) else { return }
    let cookies: [[HTTPCookiePropertyKey: Any]] = [
      [.name: "SOCS", .value: "CAESHAgBEhJnd3NfMjAyMzA4MTAtMF9SQzIaAmVuIAEaBgiAo_CmBg"],
      [.name: "CONSENT", .value: "PENDING+987"],
    ]
    for var properties in cookies {
      properties[.domain] = ".google.com"
      properties[.path] = "/"
      properties[.secure] = "TRUE"
      properties[.expires] = Date(timeIntervalSinceNow: 365 * 24 * 3600)
      if let cookie = HTTPCookie(properties: properties) { await store.setCookie(cookie) }
    }
  }
}

/// Small regular-expression helpers for reading page text.
enum Rx {
  static func match(_ pattern: String, _ text: String, caseSensitive: Bool = false) -> [String?]? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: caseSensitive ? [] : [.caseInsensitive]) else { return nil }
    let ns = text as NSString
    guard let result = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
    return (0..<result.numberOfRanges).map { index in
      let range = result.range(at: index)
      return range.location == NSNotFound ? nil : ns.substring(with: range)
    }
  }

  static func all(_ pattern: String, _ text: String, caseSensitive: Bool = false) -> [[String?]] {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: caseSensitive ? [] : [.caseInsensitive]) else { return [] }
    let ns = text as NSString
    return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { result in
      (0..<result.numberOfRanges).map { index in
        let range = result.range(at: index)
        return range.location == NSNotFound ? nil : ns.substring(with: range)
      }
    }
  }

  /// The first number in text such as "US$1,234" or "€ 98.50".
  static func number(_ text: String?) -> Double? {
    guard let text, let found = match(#"\d[\d,]*(?:\.\d+)?"#, text)?.first ?? nil else { return nil }
    return Double(found.replacingOccurrences(of: ",", with: ""))
  }

  /// "2 hr 5 min", "45 min", "3 hr" → minutes.
  static func minutes(_ text: String) -> Int {
    let hours = match(#"(\d+)\s*hr"#, text)?[1].flatMap { Int($0) } ?? 0
    let mins = match(#"(\d+)\s*min"#, text)?[1].flatMap { Int($0) } ?? 0
    return hours * 60 + mins
  }

  /// Web pages use narrow and non-breaking spaces around times ("8:05 PM").
  static func normalizeSpaces(_ text: String) -> String {
    text.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
  }
}
