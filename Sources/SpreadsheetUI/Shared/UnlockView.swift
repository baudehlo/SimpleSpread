import SwiftUI

/// The strip over a reader-mode document's formula bar: what still works,
/// and the way to edit again.
struct ReaderModeBanner: View {
    @ObservedObject private var license = AppLicense.shared

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "book")
                .foregroundStyle(.secondary)
            Text(message)
                .font(.system(size: 12))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if license.isUnlockAvailable {
                Button(license.status == .trialAvailable ? "Start Free Trial…" : "Unlock…") {
                    license.presentUnlock()
                }
                .controlSize(.small)
                .accessibilityIdentifier("readerModeUnlock")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.yellow.opacity(0.16))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("readerModeBanner")
    }

    private var message: String {
        let can = "You can view, copy, sort and filter, but not edit or save."
        switch license.status {
        case .trialAvailable: return "Reader mode. \(can) Start your free 14-day trial to edit."
        case .expired: return "Reader mode: your free trial has ended. \(can)"
        default: return "Reader mode. \(can)"
        }
    }
}

/// The status bar's reminder of the trial: days left, or the offer of it.
struct TrialBadge: View {
    @ObservedObject private var license = AppLicense.shared

    var body: some View {
        if let title {
            Button(title) { license.presentUnlock() }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .foregroundStyle(Color.accentColor)
                .tip("Unlock SimpleSpread to keep editing after the trial")
                .accessibilityIdentifier("trialBadge")
        }
    }

    private var title: String? {
        switch license.status {
        case .trial:
            let days = license.trialDaysLeft()
            return days == 1 ? "Free trial: last day" : "Free trial: \(days) days left"
        case .trialAvailable: return "Start Free Trial"
        default: return nil
        }
    }
}

#if STORE_LICENSE
/// The unlock window: the trial's terms (as App Review asks, before it
/// starts: how long, what stops working, and what the unlock costs), Start
/// Free Trial, Unlock and Restore Purchases.
struct UnlockView: View {
    @ObservedObject private var license = AppLicense.shared
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "tablecells")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.title2.weight(.semibold))
                    if let subtitle {
                        Text(subtitle)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                point("checkmark.circle", "Everything works for 14 days",
                      "Formulas, charts, pivot tables, and saving to Excel files. No account needed.")
                point("book", "Then SimpleSpread becomes a reader",
                      "You can still open, view, copy, sort and filter spreadsheets, but not edit or save them.")
                point("lock.open", "Unlock once for \(price)",
                      "Edit and save for good. One purchase covers SimpleSpread on Mac and iPad. No subscription.")
            }

            if let message = license.message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 10) {
                if license.status == .trialAvailable {
                    wideButton("Start 14-Day Free Trial", prominent: true) {
                        Task { await license.startTrial() }
                    }
                    .accessibilityIdentifier("startTrial")
                }
                wideButton("Unlock for \(price)", prominent: license.status != .trialAvailable) {
                    Task { await license.purchaseUnlock() }
                }
                .accessibilityIdentifier("unlock")
                HStack {
                    Button("Restore Purchases") {
                        Task { await license.restore() }
                    }
                    Spacer()
                    if license.isBusy { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Not Now", action: close)
                        .keyboardShortcut(.cancelAction)
                }
                .buttonStyle(.borderless)
            }
            .disabled(license.isBusy)
        }
        .padding(24)
        .frame(width: 420)
        .onChange(of: license.allowsEditing) { _, editing in
            if editing, license.status != .checking { close() }
        }
    }

    private var price: String { license.unlockPrice ?? "US$9.99" }

    private var title: String {
        switch license.status {
        case .trialAvailable: "Try SimpleSpread free for 14 days"
        case .expired: "Your free trial has ended"
        default: "Unlock SimpleSpread"
        }
    }

    private var subtitle: String? {
        switch license.status {
        case .trial:
            let days = license.trialDaysLeft()
            return days == 1 ? "Your free trial ends today." : "\(days) days left in your free trial."
        case .expired: return "Unlock SimpleSpread to edit and save again."
        default: return nil
        }
    }

    private func point(_ symbol: String, _ heading: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(heading).fontWeight(.medium)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func wideButton(_ title: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        let button = Button(action: action) {
            Text(title).frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        if prominent {
            button.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        } else {
            button.buttonStyle(.bordered)
        }
    }
}
#endif
