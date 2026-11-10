# Farezzo

A native SwiftUI iPhone app that hunts for the lowest prices on **flights**, **flight + hotel**
packages and **hotels**. It is built for the **iPhone Duo**: folded it's a single column;
unfolded, results and the selected deal sit side by side. Held partly folded, the two columns
meet at the fold, so nothing runs across the crease.

## No-key mode (no sign-up)

Out of the box Farezzo needs no accounts. Without a SerpApi key it reads **Google Flights** (flights)
and **Booking.com** (stays) the way a browser would: the pages load in a hidden web view on the
iPhone and the results are read off them, two pages at a time. If a site asks you to confirm
you're human, the results screen offers to open the page so you can tap through it. Two caveats:
reading pages this way isn't allowed by those sites' terms of use, and a site redesign can break
it until the app is updated. It can be turned off in Settings.

Keys are optional upgrades: SerpApi replaces no-key mode with more dependable servers (plus every
booking site's hotel prices and other regions' fares), and Travelpayouts adds the cheapest-day
calendar and low-cost-airline fares.

## Where the prices come from (with keys)

| Source | Covers | Cost |
| --- | --- | --- |
| **Google Flights & Google Hotels** via [SerpApi](https://serpapi.com) | Almost every airline and online travel agency; for hotels Booking.com, Expedia, Hotels.com, Agoda, Trip.com, the hotel's own site and more | One plan search per request |
| **[Duffel](https://duffel.com)** | Live fares straight from airlines' own systems (NDC), including fares agencies don't get | Free to search |
| **[Travelpayouts / Aviasales](https://www.travelpayouts.com/developers/api)** | Recent lowest fares from hundreds of agencies and low-cost carriers; the cheapest-day calendar | Free |

Add the keys in **Settings**. They're stored in the iPhone's Keychain and sent only to their own
provider. Any one source works on its own; with all three, Farezzo covers as much of the market as
public APIs allow.

## How it finds deals

- **Every source at once.** All sources are searched in parallel, prices are converted to your
  currency, and when several sources find the same flights the lowest price wins.
- **All and nearby airports.** A city covers all its airports (e.g. NYC → JFK, EWR, LGA), plus
  nearby alternatives (HPN, ISP, SWF) where low-cost airlines often fly.
- **Flexible dates.** The free fare calendar ranks the days around yours; the cheapest are then
  searched live. The calendar strip lets you jump to any day.
- **Split tickets.** Two one-way tickets (often on different airlines) are compared with round-trip
  fares.
- **Other regions.** The same search is run on Google Flights from other countries, where some
  booking sites sell the same flights for less.
- **Every booking site.** For the strongest hotels, every site's price is compared, and the
  "Compare every seller's price" button on a flight lists every agency and airline selling those
  exact flights.
- **Vacation rentals** are searched alongside hotels.
- **Price watches.** Tap the bell on any results screen. The search is re-checked in the
  background, with a notification when the price drops 5% or more or reaches your target.

Flight + hotel packages are built from the cheapest flight and stay, each booked on its own site.
Bundled package rates aren't available through any public API, and booking the two separately is
usually just as cheap (and each can be cancelled on its own).

The deep-search options each use extra SerpApi searches. The search screen shows how many a search
will use; switch options off to save searches.

## Building

Needs **Xcode 27.1 or later**: built with the iOS 27.1 SDK, the app fills both iPhone Duo displays
and can read the position of the fold.

```bash
brew install xcodegen
```

```bash
xcodegen generate
```

```bash
open Farezzo.xcodeproj
```

### CI

`.github/workflows/build.yml` runs on GitHub's `xcode-27` runner (macOS 27, Xcode 27.x, with the
iPhone Duo simulator). It builds an unsigned `Farezzo.ipa` (download it from the run's
**Artifacts**). The unit tests aren't run in CI (the simulator adds several minutes); run them in
Xcode with ⌘U. Pushing a `v*` tag also
publishes the IPA as a GitHub release. Sign the IPA with your own certificate or sideloading tool
to install it.

## Layout

```
Farezzo/Core        models, JSON, networking, Keychain, currency conversion, airport groups
Farezzo/Providers   SerpApi (Google Flights/Hotels), Duffel, Travelpayouts
Farezzo/Engine      DealEngine (the search strategy), SearchSession, WatchStore
Farezzo/Views       SwiftUI screens; FoldLayout.swift has the iPhone Duo layout
FarezzoTests        parsing and deal-ranking tests
```
