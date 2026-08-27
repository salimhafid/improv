import Foundation

#if DEBUG
/// `UITEST_FAKE_TICKETS=1` seeds a signed-in account and sample tickets so the
/// wallet renders without a real UCB login — used for screenshot verification
/// of QR sizing/layout. DEBUG builds only; in-memory only (never persisted).
enum DebugFixtures {
    static var fakeTickets: Bool {
        ProcessInfo.processInfo.environment["UITEST_FAKE_TICKETS"] == "1"
            || ProcessInfo.processInfo.arguments.contains("-UITestFakeTickets")
    }

    /// `UITEST_RESTORING=1` holds the account in the launch-restore phase, so
    /// the Tickets tab's optimistic state (cached QR + "Updating…" chip) and
    /// its no-cache placeholder can be captured. Combine with
    /// `UITEST_FAKE_TICKETS=1` to put a cached wallet behind it.
    static var stuckRestoring: Bool {
        ProcessInfo.processInfo.environment["UITEST_RESTORING"] == "1"
    }

    @MainActor
    static func seed(account: UCBAccountStore, tickets: TicketStore) {
        print("DebugFixtures: seeding fake tickets (args: \(ProcessInfo.processInfo.arguments))")
        account.debugForceSignedIn(name: "Sample Student")
        tickets.debugSeed(
            studentID: Ticket(kind: .studentID, title: "UCB Student ID",
                              source: "ucb_ny", qrSVG: sampleQR, name: "Sample Student"),
            reserved: [Ticket(kind: .reserved, orderID: "738265",
                              title: "THE PROPHECY",
                              venueLabel: "NY - 14TH ST. MAINSTAGE", source: "ucb_ny",
                              start: "2026-08-14T19:00", qrSVG: sampleQR,
                              releaseNonce: "debug",
                              posterURL: "https://ucbcomedy.com/wp-content/uploads/2026/07/Edits-various-show-posters-2026-07-09T150454.087.jpg")])
    }

    /// A real, scannable sample QR (payload "UCB-STUDENT-SAMPLE-000738265"),
    /// structurally identical to UCB's inline path-drawn SVG.
    static let sampleQR = "<svg xmlns=\"http://www.w3.org/2000/svg\" class=\"qr-svg qrcode\" viewBox=\"0 0 29 29\" preserveAspectRatio=\"xMidYMid\"><path fill=\"#fff\" d=\"M0 0 h29 v29 h-29Z\"/><path fill=\"#000\" d=\"M2 2 h1v1h-1Z M3 2 h1v1h-1Z M4 2 h1v1h-1Z M5 2 h1v1h-1Z M6 2 h1v1h-1Z M7 2 h1v1h-1Z M8 2 h1v1h-1Z M10 2 h1v1h-1Z M14 2 h1v1h-1Z M16 2 h1v1h-1Z M17 2 h1v1h-1Z M18 2 h1v1h-1Z M20 2 h1v1h-1Z M21 2 h1v1h-1Z M22 2 h1v1h-1Z M23 2 h1v1h-1Z M24 2 h1v1h-1Z M25 2 h1v1h-1Z M26 2 h1v1h-1Z M2 3 h1v1h-1Z M8 3 h1v1h-1Z M11 3 h1v1h-1Z M16 3 h1v1h-1Z M18 3 h1v1h-1Z M20 3 h1v1h-1Z M26 3 h1v1h-1Z M2 4 h1v1h-1Z M4 4 h1v1h-1Z M5 4 h1v1h-1Z M6 4 h1v1h-1Z M8 4 h1v1h-1Z M11 4 h1v1h-1Z M13 4 h1v1h-1Z M14 4 h1v1h-1Z M17 4 h1v1h-1Z M18 4 h1v1h-1Z M20 4 h1v1h-1Z M22 4 h1v1h-1Z M23 4 h1v1h-1Z M24 4 h1v1h-1Z M26 4 h1v1h-1Z M2 5 h1v1h-1Z M4 5 h1v1h-1Z M5 5 h1v1h-1Z M6 5 h1v1h-1Z M8 5 h1v1h-1Z M10 5 h1v1h-1Z M11 5 h1v1h-1Z M12 5 h1v1h-1Z M13 5 h1v1h-1Z M15 5 h1v1h-1Z M17 5 h1v1h-1Z M20 5 h1v1h-1Z M22 5 h1v1h-1Z M23 5 h1v1h-1Z M24 5 h1v1h-1Z M26 5 h1v1h-1Z M2 6 h1v1h-1Z M4 6 h1v1h-1Z M5 6 h1v1h-1Z M6 6 h1v1h-1Z M8 6 h1v1h-1Z M10 6 h1v1h-1Z M11 6 h1v1h-1Z M12 6 h1v1h-1Z M15 6 h1v1h-1Z M16 6 h1v1h-1Z M17 6 h1v1h-1Z M18 6 h1v1h-1Z M20 6 h1v1h-1Z M22 6 h1v1h-1Z M23 6 h1v1h-1Z M24 6 h1v1h-1Z M26 6 h1v1h-1Z M2 7 h1v1h-1Z M8 7 h1v1h-1Z M10 7 h1v1h-1Z M12 7 h1v1h-1Z M16 7 h1v1h-1Z M17 7 h1v1h-1Z M18 7 h1v1h-1Z M20 7 h1v1h-1Z M26 7 h1v1h-1Z M2 8 h1v1h-1Z M3 8 h1v1h-1Z M4 8 h1v1h-1Z M5 8 h1v1h-1Z M6 8 h1v1h-1Z M7 8 h1v1h-1Z M8 8 h1v1h-1Z M10 8 h1v1h-1Z M12 8 h1v1h-1Z M14 8 h1v1h-1Z M16 8 h1v1h-1Z M18 8 h1v1h-1Z M20 8 h1v1h-1Z M21 8 h1v1h-1Z M22 8 h1v1h-1Z M23 8 h1v1h-1Z M24 8 h1v1h-1Z M25 8 h1v1h-1Z M26 8 h1v1h-1Z M10 9 h1v1h-1Z M13 9 h1v1h-1Z M17 9 h1v1h-1Z M18 9 h1v1h-1Z M2 10 h1v1h-1Z M6 10 h1v1h-1Z M8 10 h1v1h-1Z M9 10 h1v1h-1Z M10 10 h1v1h-1Z M12 10 h1v1h-1Z M17 10 h1v1h-1Z M19 10 h1v1h-1Z M20 10 h1v1h-1Z M21 10 h1v1h-1Z M22 10 h1v1h-1Z M23 10 h1v1h-1Z M26 10 h1v1h-1Z M5 11 h1v1h-1Z M6 11 h1v1h-1Z M7 11 h1v1h-1Z M9 11 h1v1h-1Z M10 11 h1v1h-1Z M12 11 h1v1h-1Z M15 11 h1v1h-1Z M16 11 h1v1h-1Z M19 11 h1v1h-1Z M20 11 h1v1h-1Z M25 11 h1v1h-1Z M2 12 h1v1h-1Z M3 12 h1v1h-1Z M4 12 h1v1h-1Z M6 12 h1v1h-1Z M7 12 h1v1h-1Z M8 12 h1v1h-1Z M9 12 h1v1h-1Z M17 12 h1v1h-1Z M18 12 h1v1h-1Z M19 12 h1v1h-1Z M20 12 h1v1h-1Z M21 12 h1v1h-1Z M22 12 h1v1h-1Z M24 12 h1v1h-1Z M25 12 h1v1h-1Z M2 13 h1v1h-1Z M4 13 h1v1h-1Z M6 13 h1v1h-1Z M10 13 h1v1h-1Z M11 13 h1v1h-1Z M12 13 h1v1h-1Z M13 13 h1v1h-1Z M14 13 h1v1h-1Z M17 13 h1v1h-1Z M18 13 h1v1h-1Z M24 13 h1v1h-1Z M25 13 h1v1h-1Z M2 14 h1v1h-1Z M4 14 h1v1h-1Z M5 14 h1v1h-1Z M8 14 h1v1h-1Z M10 14 h1v1h-1Z M12 14 h1v1h-1Z M13 14 h1v1h-1Z M15 14 h1v1h-1Z M16 14 h1v1h-1Z M19 14 h1v1h-1Z M22 14 h1v1h-1Z M25 14 h1v1h-1Z M26 14 h1v1h-1Z M2 15 h1v1h-1Z M3 15 h1v1h-1Z M4 15 h1v1h-1Z M5 15 h1v1h-1Z M6 15 h1v1h-1Z M7 15 h1v1h-1Z M9 15 h1v1h-1Z M11 15 h1v1h-1Z M12 15 h1v1h-1Z M14 15 h1v1h-1Z M16 15 h1v1h-1Z M19 15 h1v1h-1Z M22 15 h1v1h-1Z M4 16 h1v1h-1Z M5 16 h1v1h-1Z M6 16 h1v1h-1Z M8 16 h1v1h-1Z M9 16 h1v1h-1Z M10 16 h1v1h-1Z M13 16 h1v1h-1Z M14 16 h1v1h-1Z M15 16 h1v1h-1Z M16 16 h1v1h-1Z M17 16 h1v1h-1Z M18 16 h1v1h-1Z M19 16 h1v1h-1Z M20 16 h1v1h-1Z M23 16 h1v1h-1Z M25 16 h1v1h-1Z M4 17 h1v1h-1Z M6 17 h1v1h-1Z M7 17 h1v1h-1Z M10 17 h1v1h-1Z M11 17 h1v1h-1Z M13 17 h1v1h-1Z M15 17 h1v1h-1Z M18 17 h1v1h-1Z M20 17 h1v1h-1Z M22 17 h1v1h-1Z M24 17 h1v1h-1Z M2 18 h1v1h-1Z M3 18 h1v1h-1Z M7 18 h1v1h-1Z M8 18 h1v1h-1Z M9 18 h1v1h-1Z M10 18 h1v1h-1Z M11 18 h1v1h-1Z M14 18 h1v1h-1Z M15 18 h1v1h-1Z M17 18 h1v1h-1Z M18 18 h1v1h-1Z M19 18 h1v1h-1Z M20 18 h1v1h-1Z M21 18 h1v1h-1Z M22 18 h1v1h-1Z M24 18 h1v1h-1Z M25 18 h1v1h-1Z M26 18 h1v1h-1Z M10 19 h1v1h-1Z M15 19 h1v1h-1Z M16 19 h1v1h-1Z M18 19 h1v1h-1Z M22 19 h1v1h-1Z M24 19 h1v1h-1Z M25 19 h1v1h-1Z M26 19 h1v1h-1Z M2 20 h1v1h-1Z M3 20 h1v1h-1Z M4 20 h1v1h-1Z M5 20 h1v1h-1Z M6 20 h1v1h-1Z M7 20 h1v1h-1Z M8 20 h1v1h-1Z M10 20 h1v1h-1Z M12 20 h1v1h-1Z M18 20 h1v1h-1Z M20 20 h1v1h-1Z M22 20 h1v1h-1Z M23 20 h1v1h-1Z M2 21 h1v1h-1Z M8 21 h1v1h-1Z M11 21 h1v1h-1Z M14 21 h1v1h-1Z M16 21 h1v1h-1Z M18 21 h1v1h-1Z M22 21 h1v1h-1Z M23 21 h1v1h-1Z M25 21 h1v1h-1Z M26 21 h1v1h-1Z M2 22 h1v1h-1Z M4 22 h1v1h-1Z M5 22 h1v1h-1Z M6 22 h1v1h-1Z M8 22 h1v1h-1Z M10 22 h1v1h-1Z M11 22 h1v1h-1Z M12 22 h1v1h-1Z M13 22 h1v1h-1Z M15 22 h1v1h-1Z M16 22 h1v1h-1Z M18 22 h1v1h-1Z M19 22 h1v1h-1Z M20 22 h1v1h-1Z M21 22 h1v1h-1Z M22 22 h1v1h-1Z M23 22 h1v1h-1Z M25 22 h1v1h-1Z M2 23 h1v1h-1Z M4 23 h1v1h-1Z M5 23 h1v1h-1Z M6 23 h1v1h-1Z M8 23 h1v1h-1Z M11 23 h1v1h-1Z M14 23 h1v1h-1Z M18 23 h1v1h-1Z M21 23 h1v1h-1Z M24 23 h1v1h-1Z M26 23 h1v1h-1Z M2 24 h1v1h-1Z M4 24 h1v1h-1Z M5 24 h1v1h-1Z M6 24 h1v1h-1Z M8 24 h1v1h-1Z M11 24 h1v1h-1Z M13 24 h1v1h-1Z M14 24 h1v1h-1Z M15 24 h1v1h-1Z M16 24 h1v1h-1Z M20 24 h1v1h-1Z M22 24 h1v1h-1Z M23 24 h1v1h-1Z M25 24 h1v1h-1Z M2 25 h1v1h-1Z M8 25 h1v1h-1Z M11 25 h1v1h-1Z M13 25 h1v1h-1Z M15 25 h1v1h-1Z M19 25 h1v1h-1Z M20 25 h1v1h-1Z M21 25 h1v1h-1Z M23 25 h1v1h-1Z M25 25 h1v1h-1Z M26 25 h1v1h-1Z M2 26 h1v1h-1Z M3 26 h1v1h-1Z M4 26 h1v1h-1Z M5 26 h1v1h-1Z M6 26 h1v1h-1Z M7 26 h1v1h-1Z M8 26 h1v1h-1Z M10 26 h1v1h-1Z M11 26 h1v1h-1Z M14 26 h1v1h-1Z M15 26 h1v1h-1Z M17 26 h1v1h-1Z M18 26 h1v1h-1Z M19 26 h1v1h-1Z M26 26 h1v1h-1Z\"/></svg>"
}
#endif
