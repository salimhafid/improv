import Foundation

/// Mirrors the app's persisted state to iCloud (`NSUbiquitousKeyValueStore`) so
/// settings, the I'm-Going list, and tickets follow the user across devices and
/// reinstalls. No servers of our own — the key-value store rides the user's
/// iCloud account (1 MB, plenty for this app's state).
///
/// The store has no per-key timestamps, so the strategy is deliberately simple:
/// - No local value yet (fresh install) → adopt the cloud copy.
/// - Local change → push to the cloud (last writer wins).
/// - External cloud change → adopt the reported keys. File-backed stores
///   (I'm Going, tickets) reload live via `fileDidChange`; `@AppStorage` keys
///   update live on their own; store-held settings apply on next launch.
@MainActor
enum CloudSync {
    /// UserDefaults keys mirrored to iCloud. Feed caches stay local.
    static let defaultsKeys = [
        "selectedTheaters", "filters", "classGrouping", "classAlertPrefs",
        "calendarProvider", "ucbCoreExpanded",
    ]

    /// AppSupport JSON files mirrored to iCloud (as `file/<name>` data keys).
    static let fileNames = ["going.json", "tickets.json"]

    /// Posted (with the file name as the object) after an external cloud change
    /// was written to disk — the owning store should reload.
    static let fileDidChange = Notification.Name("CloudSync.fileDidChange")

    private static let kv = NSUbiquitousKeyValueStore.default

    /// Call once at launch, BEFORE the stores read their persisted state, so a
    /// fresh install starts from the cloud copy.
    static func bootstrap() {
        for key in defaultsKeys where UserDefaults.standard.object(forKey: key) == nil {
            if let value = kv.object(forKey: key) {
                UserDefaults.standard.set(value, forKey: key)
            }
        }
        for name in fileNames {
            let url = AppSupport.file(name)
            if !FileManager.default.fileExists(atPath: url.path),
               let data = kv.data(forKey: "file/\(name)") {
                try? data.write(to: url, options: .atomic)
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kv, queue: .main
        ) { note in
            let changed = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] ?? []
            MainActor.assumeIsolated { applyExternal(changedKeys: changed) }
        }
        // Push on every defaults change — cheap (only differing keys write),
        // and covers @AppStorage writes without per-site hooks.
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { pushDefaults() }
        }
        kv.synchronize()
    }

    /// Mirror a file-backed store's save. Called from the store's own save().
    static func pushFile(_ name: String, _ data: Data) {
        kv.set(data, forKey: "file/\(name)")
    }

    // MARK: - Internals

    private static func pushDefaults() {
        for key in defaultsKeys {
            let local = UserDefaults.standard.object(forKey: key)
            let cloud = kv.object(forKey: key)
            switch (local, cloud) {
            case (nil, nil):
                continue
            case (let l?, let c?) where (l as? NSObject) == (c as? NSObject):
                continue
            case (nil, _?):
                // Never delete cloud state from a device that merely hasn't
                // set the key — deletions aren't a sync signal here.
                continue
            default:
                kv.set(local, forKey: key)
            }
        }
    }

    private static func applyExternal(changedKeys: [String]) {
        for key in changedKeys {
            if defaultsKeys.contains(key) {
                if let value = kv.object(forKey: key) {
                    UserDefaults.standard.set(value, forKey: key)
                }
            } else if key.hasPrefix("file/") {
                let name = String(key.dropFirst("file/".count))
                guard fileNames.contains(name), let data = kv.data(forKey: key) else { continue }
                try? data.write(to: AppSupport.file(name), options: .atomic)
                NotificationCenter.default.post(name: fileDidChange, object: name)
            }
        }
    }
}
