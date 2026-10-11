import Foundation
import Observation
import StoreKit

/// Whether Class Alerts are unlocked on this device, and the $9.99 purchase
/// that unlocks them (StoreKit 2).
///
/// Inputs, re-read on launch, every foreground and every transaction update:
/// the IAP among `Transaction.currentEntitlements` (works offline from the
/// device's cache); `AppTransaction` for the StoreKit environment and the
/// original download's build (grandfathering); and, outside production only,
/// the remote TestFlight switch in docs/app-config.json.
/// `ClassAlertsAccessPolicy.decide` turns them into `state`, and
/// `ClassAlertsStore` reconciles subscriptions against it via `onStateChange`.
@MainActor
@Observable
final class ClassAlertsAccess {
    /// Starts `.unknown` — or unlocked when an earlier launch proved this
    /// install grandfathered, so an offline launch never shows that user the
    /// paywall.
    private(set) var state: ClassAlertsAccessState
    /// The IAP, once loaded (for its localized price and to buy it).
    private(set) var product: Product?
    /// The last product load failed or came back empty; the next refresh retries.
    private(set) var productLoadFailed = false
    /// A purchase or a restore is in flight. Both put up App Store sheets, so
    /// one flag covers them and the paywall can disable both buttons while
    /// either runs instead of stacking a second operation.
    private(set) var isPurchasing = false
    /// User-facing outcome of the last purchase/restore that needs saying
    /// (pending, unverified, not found, an error); nil when none.
    private(set) var purchaseMessage: String?

    var isUnlocked: Bool {
        if case .unlocked = state { return true }
        return false
    }
    var isLocked: Bool { state == .locked }

    /// Called on the main actor whenever `state` changes (the app wires
    /// `ClassAlertsStore.accessChanged` to it).
    @ObservationIgnored var onStateChange: (@MainActor () -> Void)?

    /// Set once proven grandfathered in production. Local only — it must NOT
    /// join `CloudSync.defaultsKeys`: it caches what this install's App Store
    /// account proved, and iCloud would carry it to devices that may use a
    /// different one. Never cached false (a later proof of true must not be
    /// blocked); removed when StoreKit definitively says no — e.g. a TestFlight
    /// build installed over a grandfathered App Store install, which keeps the
    /// same container and would otherwise launch unlocked.
    private static let grandfatheredKey = "classAlertsGrandfathered"
    private static let configURL =
        URL(string: "https://raw.githubusercontent.com/salimhafid/improv/main/docs/app-config.json")!

    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    /// In-flight refresh, so overlapping callers (launch + the first
    /// foreground) share one pass instead of double-fetching.
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    /// A caller that needs data newer than the running pass (a transaction just
    /// finished) asks it to go round once more.
    @ObservationIgnored private var rerunRequested = false

    init() {
        state = UserDefaults.standard.bool(forKey: Self.grandfatheredKey) ? .unlocked(.grandfathered) : .unknown
    }

    /// Idempotent: starts the `Transaction.updates` listener once — so
    /// purchases approved later (Ask to Buy), made on another device, or
    /// refunded are picked up — then refreshes.
    func start() async {
        if updatesTask == nil {
            updatesTask = Task { [weak self] in
                for await update in Transaction.updates {
                    guard let self else { return }
                    guard case .verified(let transaction) = update,
                          transaction.productID == ClassAlertsAccessPolicy.productID else { continue }
                    await transaction.finish()
                    await self.refresh(rerunIfRunning: true)
                }
            }
        }
        await refresh()
    }

    /// Re-reads entitlements, AppTransaction, the remote config and the
    /// product, and recomputes `state`. Joins a pass already in flight.
    func refresh() async {
        await refresh(rerunIfRunning: false)
    }

    /// Buys the IAP. A verified purchase is finished and unlocks immediately;
    /// a pending one (Ask to Buy) arrives later through `Transaction.updates`.
    func purchase() async {
        guard let product, !isPurchasing else { return }
        isPurchasing = true
        defer { isPurchasing = false }
        purchaseMessage = nil
        do {
            switch try await product.purchase() {
            case .success(.verified(let transaction)):
                await transaction.finish()
                await refresh(rerunIfRunning: true)
                purchaseMessage = nil
            case .success(.unverified):
                purchaseMessage = "The purchase couldn't be verified."
            case .pending:
                purchaseMessage = "Purchase pending approval. Class Alerts unlock as soon as it's approved."
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            purchaseMessage = error.localizedDescription
        }
    }

    /// Explicit Restore: `AppStore.sync()` may ask for the Apple ID password,
    /// which is expected for a tap (it is why nothing else calls it).
    func restore() async {
        guard !isPurchasing else { return }
        isPurchasing = true
        defer { isPurchasing = false }
        purchaseMessage = nil
        do {
            try await AppStore.sync()
            await refresh(rerunIfRunning: true)
            if !isUnlocked {
                purchaseMessage = "No Class Alerts purchase found for this Apple ID."
            }
        } catch StoreKitError.userCancelled {
            // Dismissing the sign-in sheet isn't something to report.
        } catch {
            purchaseMessage = error.localizedDescription
        }
    }

    // MARK: Refresh

    private func refresh(rerunIfRunning: Bool) async {
        if let running = refreshTask {
            if rerunIfRunning { rerunRequested = true }
            await running.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            repeat {
                self.rerunRequested = false
                await self.recompute()
            } while self.rerunRequested
            self.refreshTask = nil
        }
        refreshTask = task
        await task.value
    }

    private func recompute() async {
        let purchased = await Self.hasPurchase()
        let (environment, originalAppVersion) = await Self.appTransactionInfo()

        var grandfathered = ClassAlertsAccessPolicy.isGrandfathered(
            originalAppVersion: originalAppVersion, environment: environment)
        let defaults = UserDefaults.standard
        switch grandfathered {
        case true?:
            if !defaults.bool(forKey: Self.grandfatheredKey) { defaults.set(true, forKey: Self.grandfatheredKey) }
        case false?:
            if defaults.object(forKey: Self.grandfatheredKey) != nil { defaults.removeObject(forKey: Self.grandfatheredKey) }
        case nil:
            // StoreKit can't say right now (offline, unverified): an earlier
            // proof still stands.
            if defaults.bool(forKey: Self.grandfatheredKey) { grandfathered = true }
        }

        // App Store builds ignore the switch, so they don't fetch it either.
        let isTestEnvironment = environment == .sandbox || environment == .xcode
        let testFlightFree = isTestEnvironment ? await Self.loadTestFlightFree() : false

        setState(ClassAlertsAccessPolicy.decide(
            purchased: purchased, grandfathered: grandfathered,
            testFlightFree: testFlightFree, environment: environment))

        // After the state, so a slow App Store lookup never delays the
        // subscription reconcile. Only the paywall needs it, so an unlocked
        // install doesn't ask.
        if product == nil && !isUnlocked { await loadProduct() }
    }

    private func setState(_ newState: ClassAlertsAccessState) {
        guard newState != state else { return }
        state = newState
        onStateChange?()
    }

    private func loadProduct() async {
        product = try? await Product.products(for: [ClassAlertsAccessPolicy.productID]).first
        productLoadFailed = product == nil
    }

    // MARK: StoreKit reads

    /// Unverified or revoked (refunded) transactions don't count.
    private static func hasPurchase() async -> Bool {
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               transaction.productID == ClassAlertsAccessPolicy.productID,
               transaction.revocationDate == nil {
                return true
            }
        }
        return false
    }

    /// Never calls `AppTransaction.refresh()`, which can show a sign-in
    /// prompt. A DEBUG build that can't read it (a simulator launch outside
    /// Xcode) is a development build, so it counts as Xcode.
    private static func appTransactionInfo() async -> (StoreEnvironmentKind, String?) {
        if case .verified(let transaction)? = try? await AppTransaction.shared {
            return (environmentKind(transaction.environment), transaction.originalAppVersion)
        }
        #if DEBUG
        return (.xcode, nil)
        #else
        return (.unknown, nil)
        #endif
    }

    private static func environmentKind(_ environment: AppStore.Environment) -> StoreEnvironmentKind {
        switch environment {
        case .production: return .production
        case .sandbox: return .sandbox
        case .xcode: return .xcode
        default: return .unknown
        }
    }

    /// The remote TestFlight switch, failing closed (see
    /// `ClassAlertsRemoteConfig.testFlightFree(feed:cacheName:)`). The raw CDN
    /// caches for 5 minutes, so a flip on main reaches testers on a
    /// foreground within minutes.
    private static func loadTestFlightFree() async -> Bool {
        await ClassAlertsRemoteConfig.testFlightFree(feed: configURL, cacheName: "app-config.cache.json")
    }
}
