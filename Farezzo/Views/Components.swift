import SwiftUI

extension DealTag {
  var color: Color {
    switch self {
    case .cheapest, .deal: return .green
    case .bestValue, .topRated: return .orange
    case .fastest: return .purple
    case .nonstop, .airlineDirect: return .blue
    case .splitTicket, .otherMarket: return .pink
    case .nearbyAirport, .flexibleDate: return .teal
    case .cached: return .gray
    case .freeCancellation: return .mint
    case .vacationRental: return .indigo
    }
  }
}

struct TagChip: View {
  let tag: DealTag
  var body: some View {
    Label(tag.title, systemImage: tag.icon)
      .font(.caption2.weight(.semibold))
      .labelStyle(.titleAndIcon)
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background(tag.color.opacity(0.14), in: Capsule())
      .foregroundStyle(tag.color)
  }
}

struct TagRow: View {
  let tags: Set<DealTag>
  var body: some View {
    let ordered = DealTag.allCases.filter { tags.contains($0) }
    if !ordered.isEmpty {
      FlowLayout(spacing: 4) {
        ForEach(ordered, id: \.self) { TagChip(tag: $0) }
      }
    }
  }
}

/// Wraps its children onto as many lines as needed.
struct FlowLayout: Layout {
  var spacing: CGFloat = 6

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? .infinity
    var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if x > 0 && x + size.width > width {
        y += lineHeight + spacing
        x = 0
        lineHeight = 0
      }
      x += size.width + spacing
      widest = max(widest, x - spacing)
      lineHeight = max(lineHeight, size.height)
    }
    return CGSize(width: min(widest, width), height: y + lineHeight)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if x > bounds.minX && x + size.width > bounds.maxX {
        y += lineHeight + spacing
        x = bounds.minX
        lineHeight = 0
      }
      subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
      x += size.width + spacing
      lineHeight = max(lineHeight, size.height)
    }
  }
}

struct AirlineLogo: View {
  let url: URL?
  var size: CGFloat = 30
  var body: some View {
    AsyncImage(url: url) { image in
      image.resizable().scaledToFit()
    } placeholder: {
      Image(systemName: "airplane").foregroundStyle(.secondary)
    }
    .frame(width: size, height: size)
    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
  }
}

struct RemoteImage: View {
  let url: URL?
  var body: some View {
    AsyncImage(url: url) { phase in
      switch phase {
      case .success(let image): image.resizable().scaledToFill()
      case .failure: Color.secondary.opacity(0.15).overlay(Image(systemName: "photo").foregroundStyle(.secondary))
      default: Color.secondary.opacity(0.1)
      }
    }
  }
}

struct StarsView: View {
  let stars: Int
  var body: some View {
    HStack(spacing: 1) {
      ForEach(0..<max(0, min(5, stars)), id: \.self) { _ in
        Image(systemName: "star.fill").font(.system(size: 9))
      }
    }
    .foregroundStyle(.yellow)
    .accessibilityLabel("\(stars) stars")
  }
}

struct RatingView: View {
  let rating: Double
  var reviews: Int?
  var body: some View {
    HStack(spacing: 3) {
      Text(rating, format: .number.precision(.fractionLength(1)))
        .font(.caption.weight(.bold))
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(ratingColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
        .foregroundStyle(ratingColor)
      if let reviews {
        Text("(\(reviews.formatted()))").font(.caption2).foregroundStyle(.secondary)
      }
    }
  }
  private var ratingColor: Color { rating >= 4.5 ? .green : rating >= 4 ? .teal : rating >= 3.5 ? .orange : .red }
}

struct SectionCard<Content: View>: View {
  let title: String?
  @ViewBuilder var content: Content

  init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let title { Text(title).font(.headline) }
      content
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
  }
}
