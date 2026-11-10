import MapKit
import SwiftUI

struct HotelRow: View {
  let hotel: HotelOffer

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      RemoteImage(url: hotel.images.first)
        .frame(width: 76, height: 76)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      VStack(alignment: .leading, spacing: 4) {
        Text(hotel.name).font(.subheadline.weight(.semibold)).lineLimit(2)
        HStack(spacing: 6) {
          if let stars = hotel.stars, stars > 0 { StarsView(stars: stars) }
          if let rating = hotel.rating { RatingView(rating: rating, reviews: hotel.reviews) }
        }
        if let cheapest = hotel.cheapestSource {
          Text("Lowest on \(cheapest.source)\(hotel.sources.count > 1 ? " · \(hotel.sources.count) sites compared" : "")")
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        TagRow(tags: hotel.tags)
      }
      Spacer(minLength: 4)
      VStack(alignment: .trailing, spacing: 2) {
        Text(Fmt.money(hotel.total, hotel.currency)).font(.headline).monospacedDigit()
        Text("\(hotel.nights) night\(hotel.nights == 1 ? "" : "s")").font(.caption2).foregroundStyle(.secondary)
        if let nightly = hotel.nightly {
          Text("\(Fmt.money(nightly, hotel.currency))/night").font(.caption2).foregroundStyle(.secondary)
        }
      }
    }
    .padding(.vertical, 4)
  }
}

struct HotelDetail: View {
  @State private var hotel: HotelOffer
  @State private var loading = false
  @State private var error: String?
  @Environment(\.openURL) private var openURL

  init(hotel: HotelOffer) {
    _hotel = State(initialValue: hotel)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      if !hotel.images.isEmpty {
        TabView {
          ForEach(hotel.images.prefix(12), id: \.self) { url in
            RemoteImage(url: url)
          }
        }
        .tabViewStyle(.page)
        .frame(height: 240)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
      }

      VStack(alignment: .leading, spacing: 6) {
        Text(hotel.name).font(.title2.bold())
        HStack(spacing: 8) {
          if let stars = hotel.stars, stars > 0 { StarsView(stars: stars) }
          if let rating = hotel.rating { RatingView(rating: rating, reviews: hotel.reviews) }
          if let kind = hotel.kind { Text(kind.capitalized).font(.caption).foregroundStyle(.secondary) }
        }
        TagRow(tags: hotel.tags)
      }

      SectionCard {
        HStack(alignment: .firstTextBaseline) {
          Text(Fmt.money(hotel.total, hotel.currency)).font(.largeTitle.bold()).monospacedDigit()
          Text("for \(hotel.nights) night\(hotel.nights == 1 ? "" : "s")").foregroundStyle(.secondary)
        }
        if let nightly = hotel.nightly {
          Text("\(Fmt.money(nightly, hotel.currency)) a night\(hotel.nightlyBeforeTaxes.map { " · \(Fmt.money($0, hotel.currency)) before taxes & fees" } ?? "")")
            .font(.subheadline).foregroundStyle(.secondary)
        }
        Text("\(Fmt.dayShort.string(from: hotel.checkIn)) – \(Fmt.dayShort.string(from: hotel.checkOut))")
          .font(.caption).foregroundStyle(.secondary)
        if let deal = hotel.dealText {
          Label(deal, systemImage: "tag.fill").font(.callout).foregroundStyle(.green)
        }
      }

      SectionCard("Prices by booking site") {
        if hotel.sources.isEmpty {
          Text("No per-site prices yet.").font(.callout).foregroundStyle(.secondary)
        }
        let cheapestID = hotel.cheapestSource?.id
        ForEach(hotel.sources.sorted { ($0.total ?? .infinity) < ($1.total ?? .infinity) }) { source in
          Button {
            if let url = source.url ?? hotel.googleURL { openURL(url) }
          } label: {
            HStack(spacing: 10) {
              AsyncImage(url: source.logo) { $0.resizable().scaledToFit() } placeholder: {
                Image(systemName: "building.2").foregroundStyle(.secondary)
              }
              .frame(width: 22, height: 22)
              VStack(alignment: .leading, spacing: 1) {
                Text(source.source).foregroundStyle(Color.primary)
                HStack(spacing: 6) {
                  if source.official { Text("Official site").font(.caption2).foregroundStyle(Color.blue) }
                  if source.freeCancellation { Text("Free cancellation").font(.caption2).foregroundStyle(Color.mint) }
                }
              }
              Spacer()
              if let total = source.total {
                VStack(alignment: .trailing, spacing: 0) {
                  Text(Fmt.money(total, hotel.currency)).font(.subheadline.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(source.id == cheapestID ? Color.green : Color.primary)
                  if let nightly = source.nightly {
                    Text("\(Fmt.money(nightly, hotel.currency))/night").font(.caption2).foregroundStyle(Color.secondary)
                  }
                }
              }
              Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(Color.secondary)
            }
            .padding(.vertical, 3)
          }
          .buttonStyle(.plain)
        }
        if hotel.propertyToken != nil {
          Button {
            Task { await loadAllSites() }
          } label: {
            HStack {
              if loading { ProgressView() }
              Label(loading ? "Checking every site…" : "Check every booking site again", systemImage: "arrow.clockwise")
            }
          }
          .buttonStyle(.bordered)
          .disabled(loading)
        }
        if let error { Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Color.orange) }
      }

      if let latitude = hotel.latitude, let longitude = hotel.longitude {
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        Map(initialPosition: .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 2500, longitudinalMeters: 2500))) {
          Marker(hotel.name, coordinate: coordinate)
        }
        .frame(height: 200)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
      }

      if let summary = hotel.summary {
        Text(summary).font(.callout)
      }

      if !hotel.amenities.isEmpty {
        SectionCard("Amenities") {
          FlowLayout(spacing: 6) {
            ForEach(hotel.amenities, id: \.self) { amenity in
              Text(amenity).font(.caption)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.secondary.opacity(0.12), in: Capsule())
            }
          }
        }
      }

      HStack {
        if let website = hotel.website {
          Button { openURL(website) } label: { Label("Hotel website", systemImage: "globe") }.buttonStyle(.bordered)
        }
        if let google = hotel.googleURL {
          Button { openURL(google) } label: { Label("Google Hotels", systemImage: "magnifyingglass") }.buttonStyle(.bordered)
        }
      }
    }
  }

  private func loadAllSites() async {
    guard let key = APIKeys.load().serpApi else { error = "Add a SerpApi key in Settings."; return }
    loading = true
    defer { loading = false }
    do {
      hotel = try await SerpApi(key: key).hotelDetails(hotel)
      error = nil
    } catch {
      self.error = error.localizedDescription
    }
  }
}

struct PackageRow: View {
  let deal: PackageDeal

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      RemoteImage(url: deal.hotel.images.first)
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      VStack(alignment: .leading, spacing: 4) {
        Text(deal.hotel.name).font(.subheadline.weight(.semibold)).lineLimit(1)
        HStack(spacing: 6) {
          if let stars = deal.hotel.stars, stars > 0 { StarsView(stars: stars) }
          if let rating = deal.hotel.rating { RatingView(rating: rating) }
        }
        Label("\(deal.flight.outbound.airlines.first ?? "Flight") · \(deal.flight.outbound.stopsText) · \(Fmt.money(deal.flight.price, deal.currency))",
              systemImage: "airplane")
          .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        Label("\(deal.hotel.nights) nights · \(Fmt.money(deal.hotel.total, deal.currency))", systemImage: "bed.double")
          .font(.caption).foregroundStyle(.secondary)
        TagRow(tags: deal.tags.union(deal.flight.tags.intersection([.splitTicket, .nonstop])))
      }
      Spacer(minLength: 4)
      VStack(alignment: .trailing, spacing: 2) {
        Text(Fmt.money(deal.total, deal.currency)).font(.headline).monospacedDigit()
        Text("total").font(.caption2).foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 4)
  }
}

struct PackageDetail: View {
  let deal: PackageDeal
  let query: SearchQuery

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      SectionCard {
        HStack(alignment: .firstTextBaseline) {
          Text(Fmt.money(deal.total, deal.currency)).font(.largeTitle.bold()).monospacedDigit()
          Text("flight + \(deal.hotel.nights) nights").foregroundStyle(.secondary)
        }
        LabeledContent("Flights", value: Fmt.money(deal.flight.price, deal.currency))
        LabeledContent("Stay", value: Fmt.money(deal.hotel.total, deal.currency))
        if query.travelers > 1 {
          LabeledContent("Per traveler", value: Fmt.money(deal.total / Double(query.travelers), deal.currency))
        }
        Text("Built from the cheapest flight and stay, each booked on its own site. Booking separately is usually cheaper than a bundled package, and you can cancel one without the other.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Text("Flight").font(.title3.bold())
      FlightDetail(offer: deal.flight, query: query)
      Divider()
      Text("Stay").font(.title3.bold())
      HotelDetail(hotel: deal.hotel)
    }
  }
}
