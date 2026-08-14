import SwiftUI

/// A single ticket, full-screen for the door: big QR, screen brightness cranked
/// so a scanner reads it in any light. Works offline — the QR is cached SVG.
struct TicketDetailView: View {
    let ticket: Ticket
    var onRelease: ((Ticket) async -> Bool)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var priorBrightness: CGFloat?
    @State private var releasing = false
    @State private var releaseError: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header

                // Full-width QR — as big as the screen allows, so the door
                // scanner reads it from a distance. Rendered from the locally
                // stored SVG, so it works with no network at all.
                QRCodeView(svg: ticket.qrSVG)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(1, contentMode: .fit)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.black.opacity(0.08)))
                    .padding(.horizontal, 12)
                    .shadow(color: .black.opacity(0.12), radius: 14, y: 6)

                Text(ticket.kind == .studentID
                     ? "Show at the door to check in."
                     : "Show at the door — you’re on the list.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if ticket.qrSVG.isEmpty {
                    Text("The QR hasn’t synced yet — pull to refresh in Tickets. Your UCB confirmation email also carries the ticket.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Theme.Space.gutter)
                }

                if ticket.kind == .reserved, ticket.isReleasable, let onRelease {
                    Button(role: .destructive) {
                        releasing = true
                        releaseError = nil
                        Task {
                            let ok = await onRelease(ticket)
                            releasing = false
                            // Only leave on success — a failed release means the
                            // ticket is still claimed, and silently popping would
                            // read as "released".
                            if ok { dismiss() }
                            else { releaseError = "Couldn’t release the ticket. Check your connection and try again." }
                        }
                    } label: {
                        if releasing { ProgressView() } else { Text("Release ticket") }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(releasing)
                    .padding(.top, 4)

                    if let releaseError {
                        Text(releaseError)
                            .font(.footnote).foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, Theme.Space.gutter)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Space.section)
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: brighten)
        .onDisappear(perform: restoreBrightness)
        // Also restore when the app is backgrounded (onDisappear doesn't fire
        // on scene changes), and re-brighten on return.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { brighten() } else { restoreBrightness() }
        }
    }

    private func brighten() {
        if priorBrightness == nil { priorBrightness = UIScreen.main.brightness }
        UIScreen.main.brightness = 1.0
    }

    private func restoreBrightness() {
        if let prior = priorBrightness {
            UIScreen.main.brightness = prior
            priorBrightness = nil
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text(ticket.kind == .studentID ? "UCB Student ID" : ticket.title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            if ticket.kind == .studentID {
                if let name = ticket.name, !name.isEmpty {
                    Text(name).font(.headline).foregroundStyle(.secondary)
                }
                Text("Standby entry · free student ticket")
                    .font(.footnote).foregroundStyle(.tertiary)
            } else {
                Text([ticket.whenLabel, Ticket.cleanVenue(ticket.venueLabel)]
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, Theme.Space.gutter)
    }
}

extension Ticket {
    static func cleanVenue(_ s: String) -> String {
        s.replacingOccurrences(of: "NY – ", with: "").replacingOccurrences(of: "NY - ", with: "")
    }
}
