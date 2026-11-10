import SwiftUI

@main
struct FarezzoApp: App {
  @Environment(\.scenePhase) private var scenePhase
  @State private var watches = WatchStore.shared

  var body: some Scene {
    WindowGroup {
      RootView()
        .environment(watches)
        .tint(Color("AccentColor"))
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .background { WatchStore.scheduleBackgroundRefresh() }
    }
    .backgroundTask(.appRefresh(WatchStore.taskID)) {
      await WatchStore.runBackgroundRefresh()
    }
  }
}

struct RootView: View {
  @Environment(WatchStore.self) private var watches
  @State private var searchPath = NavigationPath()
  @State private var watchPath = NavigationPath()

  var body: some View {
    TabView {
      NavigationStack(path: $searchPath) {
        SearchView(path: $searchPath).appDestinations()
      }
        .tabItem { Label("Search", systemImage: "magnifyingglass") }
      NavigationStack(path: $watchPath) {
        WatchlistView().appDestinations()
      }
        .tabItem { Label("Watching", systemImage: "bell.badge") }
        .badge(watches.items.count)
      NavigationStack { SettingsView() }
        .tabItem { Label("Settings", systemImage: "gearshape") }
    }
  }
}
