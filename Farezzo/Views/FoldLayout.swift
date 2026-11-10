import SwiftUI

/// iPhone Duo support. Folded, the outer display is phone-sized and the app is a single column.
/// Unfolded, the window is tablet-sized: results and the selected deal sit side by side. Held
/// partly folded, the columns meet at the fold itself (`reservedRegions(kind: .division)`, iOS
/// 27.1), so nothing is drawn across the crease: like a book, list on one side and details on
/// the other; like a laptop, details above the fold and the list below.
enum Fold {
  static func crease(in proxy: GeometryProxy) -> CGRect? {
    if #available(iOS 27.1, *) {
      if let frame = proxy.reservedRegions(kind: .division).first?.frame, frame.width > 0 || frame.height > 0 {
        return frame
      }
    }
    return nil
  }

  /// Wide enough for two columns (iPhone Duo unfolded, iPad, big iPhones in landscape).
  static let twoColumnWidth: CGFloat = 680
}

struct FoldAwareSplit<ListContent: View, DetailContent: View>: View {
  private let list: (Bool) -> ListContent
  private let detail: () -> DetailContent

  init(@ViewBuilder list: @escaping (Bool) -> ListContent, @ViewBuilder detail: @escaping () -> DetailContent) {
    self.list = list
    self.detail = detail
  }

  var body: some View {
    GeometryReader { proxy in
      let size = proxy.size
      let crease = Fold.crease(in: proxy)
      if let crease, crease.height > crease.width, crease.minX > 220, crease.maxX < size.width - 220 {
        HStack(spacing: 0) {
          list(true).frame(width: crease.minX)
          Color.clear.frame(width: crease.width)
          detail().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      } else if let crease, crease.width > crease.height, crease.minY > 180, crease.maxY < size.height - 180 {
        VStack(spacing: 0) {
          detail().frame(height: crease.minY)
          Color.clear.frame(height: crease.height)
          list(true).frame(maxHeight: .infinity)
        }
      } else if size.width >= Fold.twoColumnWidth {
        HStack(spacing: 0) {
          list(true).frame(width: min(max(size.width * 0.42, 340), 480))
          Divider().ignoresSafeArea(edges: .bottom)
          detail().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      } else {
        list(false)
      }
    }
  }
}

/// Keeps a form at a readable width on a wide window.
struct ReadableWidth: ViewModifier {
  var maxWidth: CGFloat = 720
  func body(content: Content) -> some View {
    GeometryReader { proxy in
      content.contentMargins(.horizontal, max(0, (proxy.size.width - maxWidth) / 2), for: .scrollContent)
    }
  }
}

extension View {
  func readableWidth(_ maxWidth: CGFloat = 720) -> some View { modifier(ReadableWidth(maxWidth: maxWidth)) }
}
