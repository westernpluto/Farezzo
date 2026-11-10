import SwiftUI
import WebKit

/// Opens a booking site inside the app. Needed for Google Flights' booking redirects, which are
/// form POSTs that Safari can't be handed as a plain link.
struct BookingSheet: View {
  let link: BookingLink
  @Environment(\.dismiss) private var dismiss
  @Environment(\.openURL) private var openURL

  var body: some View {
    NavigationStack {
      BookingWebView(link: link)
        .ignoresSafeArea(edges: .bottom)
        .safeAreaInset(edge: .top) {
          if link.highlight != nil {
            Label("Your flight is marked in green. If it doesn't open by itself, tap it.", systemImage: "hand.tap")
              .font(.footnote)
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity)
              .padding(8)
              .background(.bar)
          }
        }
        .navigationTitle(link.label)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
          if link.postBody == nil {
            ToolbarItem(placement: .topBarLeading) {
              Button { openURL(link.url) } label: { Image(systemName: "safari") }
                .accessibilityLabel("Open in Safari")
            }
          }
        }
    }
  }
}

struct BookingWebView: UIViewRepresentable {
  let link: BookingLink

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeUIView(context: Context) -> WKWebView {
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .default()
    config.applicationNameForUserAgent = "Version/18.0 Mobile/15E148 Safari/604.1"
    let view = WKWebView(frame: .zero, configuration: config)
    view.allowsBackForwardNavigationGestures = true
    var request = URLRequest(url: link.url)
    if let body = link.postBody {
      request.httpMethod = "POST"
      request.httpBody = Data(body.utf8)
      request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    }
    view.load(request)
    if let hints = link.highlight, !hints.isEmpty {
      context.coordinator.findFlight(in: view, hints: hints)
    }
    return view
  }

  func updateUIView(_ view: WKWebView, context: Context) {}

  static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
    coordinator.stop()
  }

  /// Finds the chosen flight in Google Flights' results (by its times and airline), scrolls to
  /// it, outlines it and taps it, which opens its return flights or booking options.
  @MainActor
  final class Coordinator {
    private var task: Task<Void, Never>?

    func findFlight(in view: WKWebView, hints: [String]) {
      let hintsJSON = (try? JSONSerialization.data(withJSONObject: hints)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
      let script = Self.findScript.replacingOccurrences(of: "HINTS_JSON", with: hintsJSON)
      task = Task { [weak view] in
        var expanded = false
        for attempt in 0..<80 {
          try? await Task.sleep(for: .milliseconds(700))
          guard let view, !Task.isCancelled else { return }
          guard let result = try? await view.evaluateJavaScript(script) as? String else { continue }
          if result == "found" { return }
          // Not among the top results: open the full list once and keep looking.
          if result == "missing", attempt > 10, !expanded {
            expanded = true
            _ = try? await view.evaluateJavaScript(GoogleFlightsWeb.expandScript)
          }
        }
      }
    }

    func stop() { task?.cancel() }

    static let findScript = #"""
    (() => {
      const hints = HINTS_JSON;
      const norm = s => (s || '').replace(/[  ]/g, ' ').toLowerCase();
      const rows = Array.from(document.querySelectorAll('[aria-label^="From "]'));
      if (!rows.length) return 'loading';
      const find = hs => rows.find(e => hs.every(h => norm(e.getAttribute('aria-label')).indexOf(norm(h)) >= 0));
      const el = find(hints) || find(hints.slice(0, 2));
      if (!el) return 'missing';
      const row = el.closest('li') || el;
      row.scrollIntoView({ block: 'center' });
      row.style.outline = '3px solid #0d9188';
      row.style.outlineOffset = '2px';
      row.style.borderRadius = '12px';
      if (!document.getElementById('farezzo-mark')) {
        const badge = document.createElement('div');
        badge.id = 'farezzo-mark';
        badge.textContent = 'Your flight';
        badge.style.cssText = 'display:inline-block;margin:6px 0 2px 10px;padding:2px 8px;border-radius:8px;background:#0d9188;color:#fff;font:600 12px -apple-system,sans-serif';
        row.insertBefore(badge, row.firstChild);
      }
      setTimeout(() => {
        const r = el.getBoundingClientRect();
        const o = { bubbles: true, cancelable: true, view: window, clientX: r.left + r.width / 2, clientY: r.top + r.height / 2, button: 0 };
        ['pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click'].forEach(t => el.dispatchEvent(
          t.startsWith('pointer') ? new PointerEvent(t, { ...o, pointerType: 'touch', isPrimary: true }) : new MouseEvent(t, o)));
      }, 900);
      return 'found';
    })()
    """#
  }
}

/// No-key mode: when Google or Booking.com wants to confirm a person is there, the page is
/// shown here. It shares cookies with the hidden reader, so once it's passed, searches work again.
struct HumanCheckSheet: View {
  let url: URL
  let onDone: () -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        Text("Complete the check or accept the cookie notice, then tap Search again.")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .padding(10)
        HumanCheckWebView(url: url)
      }
      .ignoresSafeArea(edges: .bottom)
      .navigationTitle(url.host ?? "Check")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Search again") {
            dismiss()
            onDone()
          }
        }
      }
    }
  }
}

private struct HumanCheckWebView: UIViewRepresentable {
  let url: URL

  func makeUIView(context: Context) -> WKWebView {
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .default()
    config.defaultWebpagePreferences.preferredContentMode = .desktop
    let view = WKWebView(frame: .zero, configuration: config)
    view.customUserAgent = WebPageReader.userAgent
    view.load(URLRequest(url: url))
    return view
  }

  func updateUIView(_ view: WKWebView, context: Context) {}
}
