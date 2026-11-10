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

  func makeUIView(context: Context) -> WKWebView {
    let view = WKWebView()
    view.allowsBackForwardNavigationGestures = true
    var request = URLRequest(url: link.url)
    if let body = link.postBody {
      request.httpMethod = "POST"
      request.httpBody = Data(body.utf8)
      request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    }
    view.load(request)
    return view
  }

  func updateUIView(_ view: WKWebView, context: Context) {}
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
