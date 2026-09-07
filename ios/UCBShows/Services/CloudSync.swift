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
///   update live on their own; class-alert prefs apply live too (that store
///   observes `UserDefaults` changes); the remaining store-held settings
///   (theater selection, filters) apply on next launch.
@MainActor
enum CloudSync {
    /// UserDefaults keys mirrored to iCloud. Feed caches stay local.
    static let defaultsKeys = [
        "selectedTheaters", "filters", "classAlertPrefs", "calendarProvider",
    ]

    /// AppSupport JSON files mirrored to iCloud (as `file/<name>` data keys).
    static let fileNames = ["going.json", "tickets.json"]

    /// Posted (with the file name as the object) after an external cloud change
    /// was written to disk — the owning store should reload.
    static let fileDidChange = Notification.Name("CloudSync.fileDidChange")

    private static let kv = NSUbiquitousKeyValueStore.default

    /// The store discards writes made before its initial iCloud download has
    /// landed (that download arrives asynchronously, as an external change
    /// with reason `InitialSyncChange`), so local defaults changes made in the
    /// first seconds after launch are held back until then and pushed once.
    /// Flipped by the first external-change notification, or by a short
    /// fallback delay for a device with no iCloud account to hear from.
    private static var initialSyncDone = false

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
            let reason = (note.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int) ?? -1
            MainActor.assumeIsolated { applyExternal(changedKeys: changed, reason: reason) }
        }
        // Push on every defaults change — cheap (only differing keys write),
        // and covers @AppStorage writes without per-site hooks. Held back
        // until the initial sync, when `markInitialSyncDone` flushes once.
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { if initialSyncDone { pushDefaults() } }
        }
        kv.synchronize()
        Task {
            try? await Task.sleep(for: .seconds(5))
            markInitialSyncDone()
        }
    }

    /// Mirror a file-backed store's save. Called from the store's own save().
    static func pushFile(_ name: String, _ data: Data) {
        kv.set(data, forKey: "file/\(name)")
    }

    // MARK: - Internals

    private static func markInitialSyncDone() {
        guard !initialSyncDone else { return }
        initialSyncDone = true
        pushDefaults()
    }

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

    private static func applyExternal(changedKeys: [String], reason: Int) {
        // Any external change means the store has heard from iCloud. Flush the
        // held-back defaults only once the adopted keys are in place, so the
        // flush pushes what this device adds — not values the cloud just
        // replaced (which would bounce straight back).
        defer { markInitialSyncDone() }
        switch reason {
        case NSUbiquitousKeyValueStoreAccountChange:
            // A different iCloud account signed in on this device. Its hearts
            // and tickets aren't this user's to adopt blindly — and its
            // `tickets.json` would arm reminders for shows they never
            // reserved — so leave local state alone; the flush in the `defer`
            // and every later local save push ours under the new account
            // (last writer wins, as ever).
            #if DEBUG
            print("CloudSync: iCloud account changed — not adopting \(changedKeys)")
            #endif
            return
        case NSUbiquitousKeyValueStoreQuotaViolationChange:
            // The 1 MB store is full (tickets.json carries inline QR SVG per
            // ticket). Nothing arrived; the listed keys are ours that failed
            // to write. Surfaced here so it isn't a silent stall.
            #if DEBUG
            print("CloudSync: iCloud key-value quota exceeded — failed to push \(changedKeys)")
            #endif
            return
        default:
            break
        }
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
