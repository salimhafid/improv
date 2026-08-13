import SwiftUI

/// A single ticket, full-screen for the door: big QR, screen brightness cranked
/// so a scanner reads it in any light. Works offline — the QR is cached SVG.
struct TicketDetailView: View {
    let ticket: Ticket
    var onRelease: ((Ticket) async -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var priorBrightness = UIScreen.main.brightness
    @State private var releasing = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header

                QRCodeView(svg: ticket.qrSVG)
                    .frame(maxWidth: 320)
                    .aspectRatio(1, contentMode: .fit)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.black.opacity(0.08)))
                    .padding(.horizontal, Theme.Space.gutter)
                    .shadow(color: .black.opacity(0.12), radius: 14, y: 6)

                Text(ticket.kind == .studentID
                     ? "Show at the door to check in."
                     : "Show at the door — you’re on the list.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if ticket.kind == .reserved, ticket.isReleasable, onRelease != nil {
                    Button(role: .destructive) {
                        releasing = true
                        Task { await onRelease?(ticket); releasing = false; dismiss() }
                    } label: {
                        if releasing { ProgressView() } else { Text("Release ticket") }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Space.section)
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { priorBrightness = UIScreen.main.brightness; UIScreen.main.brightness = 1.0 }
        .onDisappear { UIScreen.main.brightness = priorBrightness }
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
