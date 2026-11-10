import Foundation
#if STORE_LICENSE
import os
import StoreKit
#endif

/// Whether this copy of SimpleSpread may edit and save: the App Store's
/// 14-day trial and one-time unlock (docs/APP-STORE-TRIAL.md).
///
/// Only the App Store builds (every iPad build, and the Mac App Store build:
/// `STORE_LICENSE`) have a trial. The open source Mac build is always
/// unlocked, and none of the store code is compiled into it.
///
/// After the trial, documents open in reader mode (`SpreadsheetDocument.
/// isReadOnly`): view, copy, find, sort and filter, but no edits or saves.
/// People who bought SimpleSpread when it was a paid app keep everything.
@MainActor
public final class AppLicense: ObservableObject {
    public static let shared = AppLicense()

    public enum Status: Equatable, Sendable {
        /// Not known yet: the App Store hasn't answered (editing is allowed
        /// meanwhile, so an offline launch never locks a paying customer).
        case checking
        /// The open source build: no trial, nothing to buy.
        case openSource
        /// Bought SimpleSpread when it was a paid app.
        case paidApp
        /// Bought the unlock.
        case purchased
        /// In the free trial, which ends then.
        case trial(ends: Date)
        /// Hasn't started the trial.
        case trialAvailable
        /// The trial is over and the unlock isn't bought.
        case expired
    }

    @Published public private(set) var status: Status

    /// Editing and saving are allowed.
    public var allowsEditing: Bool {
        switch status {
        case .checking, .openSource, .paidApp, .purchased, .trial: true
        case .trialAvailable, .expired: false
        }
    }

    /// The trial or the unlock can still be bought (show the badge, the
    /// banner and the Unlock menu item).
    public var isUnlockAvailable: Bool {
        switch status {
        case .trial, .trialAvailable, .expired: true
        case .checking: checkFailed
        case .openSource, .paidApp, .purchased: false
        }
    }

    /// Whole days left in the trial, counting today (0 once it's over).
    public func trialDaysLeft(now: Date = Date()) -> Int {
        guard case .trial(let ends) = status else { return 0 }
        return Self.daysLeft(until: ends, now: now)
    }

    nonisolated static func daysLeft(until end: Date, now: Date) -> Int {
        max(0, Int((end.timeIntervalSince(now) / 86_400).rounded(.up)))
    }

    // MARK: Products

    /// Non-consumable, US$9.99: editing and saving for good, on Mac and iPad.
    nonisolated public static let unlockProductID = "com.kikiplan.simplespread.unlock"
    /// Non-consumable, free, named "14-day Trial" as App Review asks
    /// (guideline 3.1.1): when it was "bought" is when the trial began.
    nonisolated public static let trialProductID = "com.kikiplan.simplespread.trial"
    nonisolated public static let trialLength: TimeInterval = 14 * 86_400

    /// The unlock's price in the store's currency ("$9.99"), once loaded.
    @Published public private(set) var unlockPrice: String?
    /// A purchase or restore is under way.
    @Published public private(set) var isBusy = false
    /// Why the last purchase or restore didn't go through, for the unlock
    /// window to show.
    @Published public var message: String?
    /// The App Store couldn't say whether this copy was bought. The status
    /// stays `.checking` (editing allowed) and the check is retried; the
    /// unlock window offers Restore Purchases, which asks it again.
    @Published public private(set) var checkFailed = false

    // MARK: Paid-app customers

    /// The first App Store versions that were free to download. Anyone whose
    /// original download was older paid for the app. `originalAppVersion` is
    /// CFBundleShortVersionString on the Mac ("2.3.0") but CFBundleVersion,
    /// the build number, on iPad ("4"); the dots tell them apart.
    nonisolated static let firstFreeMacVersion = [2, 4, 0]
    nonisolated static let firstFreeIPadBuild = 5
    /// Also counted as bought: a first download before this date (the day
    /// 2.4.0 was built; the release date isn't known then, and earlier is
    /// the safe side). Covers a Mac customer's first iPad install, should
    /// the App Store report that platform's own version.
    nonisolated static let freeSince = DateComponents(
        calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(identifier: "UTC"),
        year: 2026, month: 11, day: 9).date!

    /// Whether an original download (see AppTransaction) was of the paid app.
    nonisolated static func boughtWhenPaid(originalAppVersion: String, originalPurchaseDate: Date) -> Bool {
        if originalPurchaseDate < freeSince { return true }
        let parts = originalAppVersion.split(separator: ".").map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return false }
        let numbers = parts.compactMap { $0 }
        if numbers.count == 1 { return numbers[0] < firstFreeIPadBuild }
        let padded = numbers + Array(repeating: 0, count: max(0, firstFreeMacVersion.count - numbers.count))
        return padded.lexicographicallyPrecedes(firstFreeMacVersion)
    }

    // MARK: Documents

    /// Open documents, so a purchase unlocks them and the trial's end locks them.
    private let documents = NSHashTable<SpreadsheetDocument>.weakObjects()

    /// A new document opens in reader mode unless editing is allowed.
    func adopt(_ document: SpreadsheetDocument) {
        #if STORE_LICENSE
        documents.add(document)
        document.isReadOnly = !allowsEditing
        #endif
    }

    /// Bring open documents in line with the status. A document with
    /// unsaved work when the trial runs out stays editable until it's
    /// closed, so the work can still be saved.
    private func applyToDocuments() {
        let editing = allowsEditing
        for document in documents.allObjects {
            if editing {
                document.isReadOnly = false
            } else if !document.isModified, !document.hasPendingEdit {
                document.isReadOnly = true
            }
        }
    }

    /// An edit was refused in reader mode: offer the unlock.
    func editRefused() {
        #if STORE_LICENSE
        presentUnlock()
        #endif
    }

    // MARK: Lifecycle

    #if STORE_LICENSE
    private var updates: Task<Void, Never>?
    private var trialTimer: Timer?
    private var started = false
    /// The status override from SIMPLESPREAD_LICENSE, which only ever
    /// restricts (screenshots and tests of the trial's states).
    private let override: Status?
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let paidApp = "license.paidApp"
        static let purchased = "license.purchased"
        static let trialEnds = "license.trialEnds"
        static let lastAutoPrompt = "license.lastAutoPrompt"
    }

    private init() {
        switch ProcessInfo.processInfo.environment["SIMPLESPREAD_LICENSE"] {
        case "new": override = .trialAvailable
        case "trial": override = .trial(ends: Date().addingTimeInterval(9 * 86_400 + 60))
        case "expired": override = .expired
        default: override = nil
        }
        status = override ?? Self.cachedStatus(UserDefaults.standard)
    }

    /// What was known at the last launch, for until the App Store answers.
    private static func cachedStatus(_ defaults: UserDefaults) -> Status {
        if defaults.bool(forKey: Keys.purchased) { return .purchased }
        if defaults.bool(forKey: Keys.paidApp) { return .paidApp }
        if let ends = defaults.object(forKey: Keys.trialEnds) as? Date {
            return ends > Date() ? .trial(ends: ends) : .expired
        }
        return .checking
    }

    /// Ask the App Store what this Apple Account owns, and keep listening
    /// (purchases on another device, refunds, Ask to Buy approvals). Once
    /// at launch; offers the trial if it hasn't been started.
    public func start() {
        guard !started else { return }
        started = true
        guard override == nil else {
            schedulePrompt()
            return
        }
        updates = Task { [weak self] in
            for await update in Transaction.updates {
                if case .verified(let transaction) = update { await transaction.finish() }
                await self?.refresh()
            }
        }
        Task {
            await refresh()
            await loadProducts()
            schedulePrompt()
        }
        NotificationCenter.default.addObserver(forName: Self.becameActive, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                AppLicense.shared.trialClockTicked()
                if AppLicense.shared.checkFailed { Task { await AppLicense.shared.recheck() } }
            }
        }
    }

    #if os(macOS)
    private static let becameActive = NSNotification.Name("NSApplicationDidBecomeActiveNotification")
    #else
    private static let becameActive = NSNotification.Name("UIApplicationDidBecomeActiveNotification")
    #endif

    /// Work out the status from the App Store's records.
    func refresh() async {
        guard override == nil else { return }
        let owned = await Self.answer(within: 20, otherwise: nil) { await Self.entitlements() }
        let purchased = owned?.purchased ?? false
        let trialStart = owned?.trialStart
        var (paidApp, failure) = await Self.answer(within: 20, otherwise: (nil, "The App Store didn’t answer.")) {
            await Self.paidAppCheck()
        }
        if owned == nil {
            Self.log.error("Transaction.currentEntitlements: no answer in 20 s")
            (paidApp, failure) = (nil, failure ?? "The App Store didn’t list your purchases.")
        }
        if let failure { lastCheckFailure = failure }
        if purchased {
            set(.purchased)
        } else if paidApp == true {
            set(.paidApp)
        } else if let trialStart {
            let ends = trialStart.addingTimeInterval(Self.trialLength)
            set(ends > Date() ? .trial(ends: ends) : .expired)
        } else if paidApp == false {
            set(.trialAvailable)
        }
        // paidApp == nil: the App Store couldn't say. Keep what we had,
        // and if that's nothing, ask again in a while.
        checkFailed = status == .checking
        if checkFailed { scheduleRetry() } else { retryCount = 0 }
    }

    private var refreshing = false
    private var retryCount = 0
    private var retryTask: Task<Void, Never>?
    /// Why the last paid-app check failed, for the unlock window.
    private var lastCheckFailure: String?

    /// Check again after 30 seconds, 2 minutes, then every 10 minutes
    /// (and whenever the app becomes active) until the App Store answers.
    private func scheduleRetry() {
        guard retryTask == nil else { return }
        let delays: [Double] = [30, 120, 600]
        let delay = delays[min(retryCount, delays.count - 1)]
        retryCount += 1
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            self?.retryTask = nil
            await self?.recheck()
        }
    }

    fileprivate func recheck() async {
        guard status == .checking, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        await refresh()
        if products.isEmpty { await loadProducts() }
        schedulePrompt()
    }

    nonisolated private static let log = Logger(subsystem: "com.kikiplan.simplespread", category: "license")

    /// Whether the original download was of the paid app; nil and the
    /// reason if the App Store couldn't say.
    nonisolated private static func paidAppCheck() async -> (Bool?, String?) {
        do {
            switch try await AppTransaction.shared {
            case .verified(let app):
                log.info("AppTransaction \(app.environment.rawValue, privacy: .public): original \(app.originalAppVersion, privacy: .public), \(String(describing: app.originalPurchaseDate), privacy: .public)")
                // Outside the App Store (TestFlight, Xcode) the original
                // version is always "1.0": test the trial there, not the
                // paid-app path.
                guard app.environment == .production else { return (false, nil) }
                return (boughtWhenPaid(originalAppVersion: app.originalAppVersion,
                                       originalPurchaseDate: app.originalPurchaseDate), nil)
            case .unverified(_, let error):
                log.error("AppTransaction unverified: \(String(describing: error), privacy: .public)")
                return (false, nil)
            }
        } catch {
            log.error("AppTransaction failed: \(String(describing: error), privacy: .public)")
            return (nil, error.localizedDescription)
        }
    }

    /// What this Apple Account owns: the unlock, and when the trial began.
    nonisolated private static func entitlements() async -> (purchased: Bool, trialStart: Date?)? {
        var purchased = false
        var trialStart: Date?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result, transaction.revocationDate == nil else { continue }
            switch transaction.productID {
            case unlockProductID: purchased = true
            case trialProductID: trialStart = min(trialStart ?? .distantFuture, transaction.originalPurchaseDate)
            default: break
            }
        }
        log.info("Entitlements: unlock \(purchased, privacy: .public), trial \(String(describing: trialStart), privacy: .public)")
        return (purchased, trialStart)
    }

    /// The App Store's answer, or `otherwise` if it takes longer than
    /// `seconds` to give one.
    nonisolated private static func answer<T: Sendable>(within seconds: Double, otherwise: T,
                                                        _ ask: @escaping @Sendable () async -> T) async -> T {
        await withCheckedContinuation { (done: CheckedContinuation<T, Never>) in
            let once = ResumeOnce(done)
            Task { once.resume(await ask()) }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                if once.resume(otherwise) { log.error("The App Store didn’t answer in \(seconds) s") }
            }
        }
    }

    private func set(_ new: Status) {
        defaults.set(new == .purchased, forKey: Keys.purchased)
        defaults.set(new == .paidApp, forKey: Keys.paidApp)
        switch new {
        case .trial(let ends): defaults.set(ends, forKey: Keys.trialEnds)
        case .expired: if defaults.object(forKey: Keys.trialEnds) == nil { defaults.set(Date(), forKey: Keys.trialEnds) }
        default: break
        }
        guard new != status else { return }
        status = new
        applyToDocuments()
        scheduleTrialEnd()
        if allowsEditing, new != .checking { UnlockPresenter.dismiss() }
    }

    /// End the trial on time, even mid-session.
    private func scheduleTrialEnd() {
        trialTimer?.invalidate()
        trialTimer = nil
        guard case .trial(let ends) = status else { return }
        // Timers stop while the Mac sleeps; becoming active checks again.
        let interval = min(ends.timeIntervalSinceNow + 1, 86_400)
        trialTimer = Timer.scheduledTimer(withTimeInterval: max(1, interval), repeats: false) { _ in
            MainActor.assumeIsolated { AppLicense.shared.trialClockTicked() }
        }
    }

    private func trialClockTicked() {
        if case .trial(let ends) = status, ends <= Date() {
            set(.expired)
        } else {
            scheduleTrialEnd()
        }
    }

    // MARK: Buying

    private var products: [String: Product] = [:]

    private func loadProducts() async {
        guard let loaded = try? await Product.products(for: [Self.unlockProductID, Self.trialProductID]) else { return }
        for product in loaded { products[product.id] = product }
        unlockPrice = products[Self.unlockProductID]?.displayPrice
    }

    /// Start the 14-day trial (a free purchase, so it follows the Apple
    /// Account to the user's other devices).
    public func startTrial() async {
        await buy(Self.trialProductID)
    }

    /// Buy the unlock.
    public func purchaseUnlock() async {
        await buy(Self.unlockProductID)
    }

    private func buy(_ id: String) async {
        guard !isBusy else { return }
        isBusy = true
        message = nil
        defer { isBusy = false }
        if products[id] == nil { await loadProducts() }
        guard let product = products[id] else {
            message = "The App Store isn’t available right now. Check your internet connection and try again."
            return
        }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                guard case .verified(let transaction) = verification else {
                    message = "The App Store couldn’t confirm the purchase. Try Restore Purchases."
                    return
                }
                await transaction.finish()
                await refresh()
            case .pending:
                message = "The purchase is waiting for approval. SimpleSpread unlocks as soon as it’s approved."
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            message = error.localizedDescription
        }
    }

    /// Restore Purchases: ask the App Store for this account's purchases
    /// again (another device, a reinstall).
    public func restore() async {
        guard !isBusy else { return }
        isBusy = true
        message = nil
        defer { isBusy = false }
        do {
            try await AppStore.sync()
        } catch StoreKitError.userCancelled {
            return
        } catch {
            message = error.localizedDescription
            return
        }
        if checkFailed {
            // Fetch the app's own record again (it may ask to sign in).
            do { _ = try await AppTransaction.refresh() } catch {
                Self.log.error("AppTransaction.refresh failed: \(String(describing: error), privacy: .public)")
            }
        }
        await refresh()
        if checkFailed {
            message = "SimpleSpread still couldn’t check your purchase with the App Store (\(lastCheckFailure ?? "no answer")). Editing stays on meanwhile."
            return
        }
        if !allowsEditing {
            message = "No purchase was found for this Apple Account."
        }
    }

    // MARK: Prompting

    /// Show the unlock window (the menu item, the banner, a refused edit).
    public func presentUnlock() {
        guard isUnlockAvailable else { return }
        UnlockPresenter.present()
    }

    /// Offer the trial at every launch until it's started, and the unlock
    /// once a day after it ends.
    private func schedulePrompt() {
        let env = ProcessInfo.processInfo.environment
        guard env["SIMPLESPREAD_SCREENSHOT"] == nil || env["SIMPLESPREAD_UNLOCK_WINDOW"] != nil else { return }
        let prompt: Bool
        switch status {
        case .trialAvailable:
            prompt = true
        case .expired:
            let last = defaults.object(forKey: Keys.lastAutoPrompt) as? Date ?? .distantPast
            prompt = Date().timeIntervalSince(last) > 20 * 3600
        default:
            prompt = false
        }
        guard prompt else { return }
        defaults.set(Date(), forKey: Keys.lastAutoPrompt)
        // After the first window is up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            MainActor.assumeIsolated { AppLicense.shared.presentUnlock() }
        }
    }
    #else
    private init() {
        status = .openSource
    }

    public func start() {}
    public func presentUnlock() {}
    #endif
}

#if STORE_LICENSE
/// Resumes a continuation once, whichever of two tasks gets there first.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    init(_ continuation: CheckedContinuation<T, Never>) { self.continuation = continuation }
    /// False if it had already been resumed.
    @discardableResult func resume(_ value: T) -> Bool {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: value)
        return c != nil
    }
}
#endif
