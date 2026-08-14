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
            VStack(spacing: 6) {
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
                .frame(width: 220, height: 52)
                .opacity(building ? 0.5 : 1)

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
