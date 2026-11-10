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
