import SwiftUI

@main
struct UCBShowsApp: App {
    @State private var store = ShowsStore()
    @State private var classesStore = ClassesStore()
    @State private var going = GoingStore()
    @State private var talent = TalentStore()
    @State private var app = AppState()

    init() {
        // Generous persistent cache so poster images load instantly on relaunch
        // (AsyncImage uses URLSession.shared → URLCache.shared).
        URLCache.shared = URLCache(memoryCapacity: 32 * 1024 * 1024,
                                   diskCapacity: 256 * 1024 * 1024)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(classesStore)
                .environment(going)
                .environment(talent)
                .environment(app)
                .tint(Theme.accent)
        }
    }
}
