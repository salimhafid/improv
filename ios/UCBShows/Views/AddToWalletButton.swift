import PassKit
import SwiftUI

/// The system "Add to Apple Wallet" button for the Student ID. Renders only
/// when a pass-signing identity is bundled (see WalletPass); tapping builds
/// the signed .pkpass on-device and presents Wallet's add sheet. Once added,
/// Wallet itself surfaces the pass on the lock screen near the theaters —
/// the app doesn't need to be running (or even installed) for that.
struct AddToWalletButton: View {
    let ticket: Ticket

    @State private var pass: PKPass?
    @State private var building = false
    @State private var error: String?

    var body: some View {
        if WalletPass.isAvailable {
            VStack(spacing: 8) {
                PassKitAddButton {
                    guard !building else { return }
                    building = true
                    error = nil
                    Task {
                        do { pass = try await WalletPass.studentIDPass(ticket: ticket) }
                        catch { self.error = error.localizedDescription }
                        building = false
                    }
                }
                // Apple's badge artwork is ~3.1:1 — an off-ratio frame stretches
                // it. Keep the canonical proportions, and clip to a larger
                // continuous corner (the artwork's own rounding is tighter, so
                // the clip defines the softer pill shape).
                .frame(width: 180, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                .opacity(building ? 0.5 : 1)
                .animation(.easeInOut(duration: 0.15), value: building)

                Text("Surfaces on your lock screen at the theater")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
            }
            .sheet(item: $pass) { pass in
                AddPassesSheet(pass: pass)
                    .ignoresSafeArea()
            }
        }
    }
}

extension PKPass: @retroactive Identifiable {
    public var id: String { serialNumber }
}

/// UIKit's black-pill Wallet button (App Store guidelines require the system
/// artwork for add-to-Wallet actions).
private struct PassKitAddButton: UIViewRepresentable {
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeUIView(context: Context) -> PKAddPassButton {
        let button = PKAddPassButton(addPassButtonStyle: .black)
        button.addTarget(context.coordinator, action: #selector(Coordinator.tap), for: .touchUpInside)
        return button
    }

    func updateUIView(_ button: PKAddPassButton, context: Context) {}

    final class Coordinator {
        let action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func tap() { action() }
    }
}

/// Wallet's own add-pass review sheet.
private struct AddPassesSheet: UIViewControllerRepresentable {
    let pass: PKPass

    func makeUIViewController(context: Context) -> UIViewController {
        PKAddPassesViewController(pass: pass) ?? UIViewController()
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {}
}
