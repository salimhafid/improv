import CryptoKit
import Foundation
import PassKit
import SwiftASN1
import UIKit
import Vision
@_spi(CMS) import X509

/// Builds a real Apple Wallet `.pkpass` for the UCB Student ID, entirely
/// on-device (the app has no server):
///
///   1. The QR *payload string* is decoded from our rasterized Student ID QR
///      with Vision — Wallet re-renders its own barcode from the payload, so
///      the scanner reads the same code UCB issued.
///   2. `pass.json` carries `locations` for both UCB theaters, which is what
///      makes Wallet surface the pass on the lock screen near the venue —
///      no geofencing, no app involvement, works even if the app is deleted.
///   3. The manifest is CMS-signed with a Pass Type ID certificate loaded
///      from the app bundle's `PassSigning/` folder (pass_cert.pem +
///      pass_key.pem, git-ignored; wwdr_g4.pem is Apple's public intermediate).
///      No certificate in the bundle → the Add-to-Wallet button simply hides.
///
/// The pass type identifier and team identifier are read from the signing
/// certificate's subject (UID and OU), so there is no extra config file.
enum WalletPass {

    struct SigningIdentity {
        let certificate: Certificate
        let privateKey: Certificate.PrivateKey
        let wwdr: Certificate
        let passTypeIdentifier: String
        let teamIdentifier: String
    }

    /// The signing identity from the bundle, if the user has provisioned one.
    static func signingIdentity() -> SigningIdentity? {
        guard
            let certPEM = bundledPEM("pass_cert"),
            let keyPEM = bundledPEM("pass_key"),
            let wwdrPEM = bundledPEM("wwdr_g4"),
            let cert = try? Certificate(pemEncoded: certPEM),
            let key = try? Certificate.PrivateKey(pemEncoded: keyPEM),
            let wwdr = try? Certificate(pemEncoded: wwdrPEM)
        else { return nil }

        // Subject of a pass cert: UID = pass type id, OU = team id.
        var passType: String?
        var team: String?
        for rdn in cert.subject {
            for attr in rdn {
                if attr.type == .RDNAttributeType.commonName { continue }
                let value = attr.value.description
                if attr.type == ASN1ObjectIdentifier("0.9.2342.19200300.100.1.1") { passType = value }
                if attr.type == .RDNAttributeType.organizationalUnitName { team = value }
            }
        }
        guard let passType, let team else { return nil }
        return SigningIdentity(certificate: cert, privateKey: key, wwdr: wwdr,
                               passTypeIdentifier: passType, teamIdentifier: team)
    }

    private static func bundledPEM(_ name: String) -> String? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "pem")
                ?? Bundle.main.url(forResource: name, withExtension: "pem", subdirectory: "PassSigning")
        else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// True when a signing identity is provisioned — gates the UI.
    @MainActor static var isAvailable: Bool { signingIdentity() != nil }

    // MARK: Build

    enum BuildError: LocalizedError {
        case noSigningIdentity, qrUndecodable, signingFailed

        var errorDescription: String? {
            switch self {
            case .noSigningIdentity: return "Wallet passes aren’t set up in this build."
            case .qrUndecodable: return "Couldn’t read the ticket’s QR payload."
            case .signingFailed: return "Couldn’t sign the Wallet pass."
            }
        }
    }

    /// Build the signed .pkpass for any ticket the app holds: the standby
    /// Student ID (generic pass, near-venue relevance for both theaters) or a
    /// reserved show ticket (event ticket, relevant at ITS venue and showtime).
    @MainActor
    static func pass(for ticket: Ticket) async throws -> PKPass {
        guard let identity = signingIdentity() else { throw BuildError.noSigningIdentity }
        guard let image = await QRRender.cachedImage(svg: ticket.qrSVG),
              let payload = decodeQRPayload(image) else { throw BuildError.qrUndecodable }

        let poster = ticket.kind == .reserved ? await fetchPoster(ticket.posterURL) : nil
        let passJSON = ticket.kind == .studentID
            ? studentIDJSON(identity: identity, ticket: ticket, payload: payload)
            : reservedJSON(identity: identity, ticket: ticket, payload: payload,
                           hasPoster: poster != nil)

        var files: [String: Data] = ["pass.json": passJSON]
        for (name, side) in [("icon.png", 29.0), ("icon@2x.png", 58.0), ("icon@3x.png", 87.0)] {
            files[name] = iconPNG(side: side)
        }
        let subtitle = ticket.kind == .studentID ? "STUDENT ID" : "STUDENT TICKET"
        for (name, scale) in [("logo.png", 1.0), ("logo@2x.png", 2.0), ("logo@3x.png", 3.0)] {
            files[name] = logoPNG(scale: scale, subtitle: subtitle)
        }
        switch ticket.kind {
        case .studentID:
            // Brick wall + spotlight + framed skull as the strip banner.
            for (suffix, scale) in [("", 1.0), ("@2x", 2.0), ("@3x", 3.0)] {
                files["strip\(suffix).png"] = brickStripPNG(scale: scale)
            }
        case .reserved:
            // The show's own poster as the strip; skull tile when a
            // website-reserved ticket carries no poster.
            if let poster {
                for (suffix, scale) in [("", 1.0), ("@2x", 2.0), ("@3x", 3.0)] {
                    files["strip\(suffix).png"] = posterStripPNG(poster: poster, scale: scale)
                }
            } else {
                for (name, side) in [("thumbnail.png", 90.0), ("thumbnail@2x.png", 180.0), ("thumbnail@3x.png", 270.0)] {
                    files[name] = thumbnailPNG(side: side)
                }
            }
        }

        // manifest.json: SHA-1 of every file (the v1 pass format's digest).
        let manifest = files.mapValues { Insecure.SHA1.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        files["manifest.json"] = manifestData

        guard let signature = try? CMS.sign(
            manifestData,
            signatureAlgorithm: .sha256WithRSAEncryption,
            additionalIntermediateCertificates: [identity.wwdr],
            certificate: identity.certificate,
            privateKey: identity.privateKey,
            signingTime: Date()
        ) else { throw BuildError.signingFailed }
        files["signature"] = Data(signature)

        let zipped = ZipWriter.archive(files: files)
        #if DEBUG
        if DebugFixtures.fakeTickets {
            // Dump for out-of-process verification (unzip -t / openssl smime).
            let dump = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("debug_pass.pkpass")
            try? zipped.write(to: dump)
        }
        #endif
        return try PKPass(data: zipped)
    }

    /// Shared card chrome: near-black, white text, UCB-red labels.
    private static func baseJSON(identity: SigningIdentity, serial: String,
                                 description: String, payload: String) -> [String: Any] {
        [
            "formatVersion": 1,
            "passTypeIdentifier": identity.passTypeIdentifier,
            "teamIdentifier": identity.teamIdentifier,
            "serialNumber": serial,
            "organizationName": "Improv",
            "description": description,
            "foregroundColor": "rgb(255,255,255)",
            "backgroundColor": "rgb(17,17,20)",
            "labelColor": "rgb(235,75,95)",
            "barcodes": [[
                "format": "PKBarcodeFormatQR",
                "message": payload,
                "messageEncoding": "iso-8859-1",
            ]],
        ]
    }

    /// Minimal Student ID card: rendered logo top left, the brick-and-spotlight
    /// strip below it, QR at the bottom. storeCard style because generic passes
    /// can't take a strip. No fields, no barcode caption. Relevant near BOTH
    /// theaters.
    private static func studentIDJSON(identity: SigningIdentity, ticket: Ticket, payload: String) -> Data {
        let serial = SHA256.hash(data: Data(payload.utf8)).prefix(12)
            .map { String(format: "%02x", $0) }.joined()
        var pass = baseJSON(identity: identity, serial: "ucb-student-id-\(serial)",
                            description: "UCB Student ID", payload: payload)
        pass["locations"] = Venue.all.map {
            ["latitude": $0.latitude, "longitude": $0.longitude,
             "relevantText": "You’re near \($0.name) — show your UCB Student ID at the door."]
        }
        pass["maxDistance"] = 300
        pass["storeCard"] = ["primaryFields": [[String: Any]]()]
        return (try? JSONSerialization.data(withJSONObject: pass)) ?? Data()
    }

    /// A reserved show: event ticket with the show name and time, relevant at
    /// ITS venue and around showtime, expiring half a day after the show.
    private static func reservedJSON(identity: SigningIdentity, ticket: Ticket, payload: String,
                                     hasPoster: Bool) -> Data {
        let qrHash = SHA256.hash(data: Data(payload.utf8)).prefix(6)
            .map { String(format: "%02x", $0) }.joined()
        var pass = baseJSON(identity: identity,
                            serial: "ucb-ticket-\(ticket.orderID ?? qrHash)",
                            description: "UCB ticket — \(ticket.title)", payload: payload)
        if let venue = Venue.forSource(ticket.source) {
            pass["locations"] = [
                ["latitude": venue.latitude, "longitude": venue.longitude,
                 "relevantText": "You’re near \(venue.name) — your ticket for \(ticket.title) is ready."],
            ]
            pass["maxDistance"] = 300
        }
        if let start = ticket.startDate {
            let iso = DateFormatter()
            iso.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxxxx"
            iso.timeZone = ticket.cityTimeZone
            pass["relevantDate"] = iso.string(from: start)
            pass["expirationDate"] = iso.string(from: start.addingTimeInterval(12 * 3600))
        }
        var secondary: [[String: Any]] = []
        if ticket.startDate != nil {
            secondary.append(["key": "when", "label": "SHOWTIME", "value": ticket.whenLabel])
        }
        let venueName = smartTitleCase(Ticket.cleanVenue(ticket.venueLabel))
        if !venueName.isEmpty {
            secondary.append(["key": "venue", "label": "VENUE", "value": venueName,
                              "textAlignment": "PKTextAlignmentRight"])
        }
        // With a poster strip the art carries the show's identity — a giant
        // overlaid title would double it. Text title only when there's no art.
        let primary: [[String: Any]] = hasPoster
            ? []
            : [["key": "show", "label": "SHOW", "value": smartTitleCase(ticket.title)]]
        pass["eventTicket"] = [
            "primaryFields": primary,
            "secondaryFields": secondary,
        ]
        return (try? JSONSerialization.data(withJSONObject: pass)) ?? Data()
    }

    /// Decode the QR's payload string from the rendered image. Vision first;
    /// CIDetector as fallback (Vision barcode detection can come up empty in
    /// the simulator).
    private static func decodeQRPayload(_ image: UIImage) -> String? {
        guard let cg = image.cgImage else { return nil }
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        let handler = VNImageRequestHandler(cgImage: cg)
        try? handler.perform([request])
        if let payload = request.results?.first?.payloadStringValue { return payload }

        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: CIContext(),
                                  options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        return detector?.features(in: CIImage(cgImage: cg))
            .compactMap { ($0 as? CIQRCodeFeature)?.messageString }.first
    }

    /// Simple red rounded square with a ticket glyph — the required pass icon.
    private static func iconPNG(side: CGFloat) -> Data {
        let size = CGSize(width: side, height: side)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            UIColor(red: 196 / 255, green: 30 / 255, blue: 58 / 255, alpha: 1).setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size),
                         cornerRadius: side * 0.22).fill()
            let config = UIImage.SymbolConfiguration(pointSize: side * 0.5, weight: .semibold)
            if let glyph = UIImage(systemName: "ticket.fill", withConfiguration: config)?
                .withTintColor(.white, renderingMode: .alwaysOriginal) {
                let g = CGRect(x: (side - glyph.size.width) / 2, y: (side - glyph.size.height) / 2,
                               width: glyph.size.width, height: glyph.size.height)
                glyph.draw(in: g)
                _ = ctx
            }
        }
        return image.pngData() ?? Data()
    }

    /// Square thumbnail shown on the card's top right: the UCB skull face
    /// (Salim's art, white-trimmed) filling a white rounded tile.
    private static func thumbnailPNG(side: CGFloat) -> Data {
        let size = CGSize(width: side, height: side)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { _ in
            let rect = CGRect(origin: .zero, size: size)
            UIBezierPath(roundedRect: rect, cornerRadius: side * 0.18).addClip()
            UIColor.white.setFill()
            UIBezierPath(rect: rect).fill()
            guard let art = UIImage(named: "ucb_skull") else { return }
            // Aspect-fit tight to the tile so the face reads large.
            let inset = side * 0.05
            let box = rect.insetBy(dx: inset, dy: inset)
            let scale = min(box.width / art.size.width, box.height / art.size.height)
            let drawSize = CGSize(width: art.size.width * scale, height: art.size.height * scale)
            art.draw(in: CGRect(x: rect.midX - drawSize.width / 2,
                                y: rect.midY - drawSize.height / 2,
                                width: drawSize.width, height: drawSize.height))
        }
        return image.pngData() ?? Data()
    }

    /// Title-case that leaves digit-led words alone ("14TH ST." -> "14th St.",
    /// where `capitalized` would produce "14Th").
    private static func smartTitleCase(_ text: String) -> String {
        text.split(separator: " ").map { word -> String in
            let lower = word.lowercased()
            guard let first = lower.first, first.isLetter else { return lower }
            return first.uppercased() + lower.dropFirst()
        }.joined(separator: " ")
    }

    private static func fetchPoster(_ urlString: String?) async -> UIImage? {
        guard let urlString, let url = URL(string: urlString),
              let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return UIImage(data: data)
    }

    /// Reserved-ticket strip: the show poster aspect-filled into the banner,
    /// with a dark scrim along the bottom so the overlaid SHOW field stays
    /// readable. eventTicket strips are 375x98 pt.
    private static func posterStripPNG(poster: UIImage, scale: CGFloat) -> Data {
        let size = CGSize(width: 375 * scale, height: 98 * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            let rect = CGRect(origin: .zero, size: size)
            // Aspect-fill, centered.
            let s = max(rect.width / poster.size.width, rect.height / poster.size.height)
            let draw = CGSize(width: poster.size.width * s, height: poster.size.height * s)
            poster.draw(in: CGRect(x: rect.midX - draw.width / 2, y: rect.midY - draw.height / 2,
                                   width: draw.width, height: draw.height))
            // Bottom scrim for field legibility.
            let colors = [UIColor.black.withAlphaComponent(0).cgColor,
                          UIColor.black.withAlphaComponent(0.62).cgColor]
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: colors as CFArray, locations: [0, 1]) {
                ctx.cgContext.drawLinearGradient(
                    g, start: CGPoint(x: 0, y: rect.height * 0.45),
                    end: CGPoint(x: 0, y: rect.height), options: [])
            }
        }
        return image.pngData() ?? Data()
    }

    /// Student ID strip: dark brick wall, one warm spotlight from above, and
    /// the skull art on a white card holding the stage. storeCard strips are
    /// 375x144 pt.
    private static func brickStripPNG(scale: CGFloat) -> Data {
        let size = CGSize(width: 375 * scale, height: 144 * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            let g = ctx.cgContext
            let rect = CGRect(origin: .zero, size: size)

            // Brick wall: mortar ground, then offset rows of bricks.
            UIColor(red: 0.098, green: 0.066, blue: 0.063, alpha: 1).setFill()  // mortar #19110F
            g.fill(rect)
            UIColor(red: 0.141, green: 0.102, blue: 0.094, alpha: 1).setFill()  // brick #241A18
            let bh: CGFloat = 21 * scale, bw: CGFloat = 50 * scale, gap: CGFloat = 3 * scale
            var y: CGFloat = 0
            var row = 0
            while y < rect.height {
                var x: CGFloat = (row % 2 == 0) ? 0 : -bw / 2
                while x < rect.width {
                    g.fill(CGRect(x: x, y: y, width: bw - gap, height: bh - gap))
                    x += bw
                }
                y += bh
                row += 1
            }

            // Spotlight pool from above.
            let warm = UIColor(red: 1.0, green: 0.87, blue: 0.67, alpha: 0.38).cgColor
            let clear = UIColor(red: 1.0, green: 0.87, blue: 0.67, alpha: 0).cgColor
            if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: [warm, clear] as CFArray, locations: [0, 1]) {
                g.drawRadialGradient(grad,
                                     startCenter: CGPoint(x: rect.midX, y: -rect.height * 0.3), startRadius: 0,
                                     endCenter: CGPoint(x: rect.midX, y: rect.midY), endRadius: rect.width * 0.52,
                                     options: [.drawsAfterEndLocation])
            }

            // The skull on a white card, catching the light.
            guard let art = UIImage(named: "ucb_skull") else { return }
            let cardH = rect.height * 0.72
            let inset = cardH * 0.10
            let artScale = (cardH - inset * 2) / art.size.height
            let cardW = art.size.width * artScale + inset * 2
            let card = CGRect(x: rect.midX - cardW / 2, y: rect.midY - cardH / 2,
                              width: cardW, height: cardH)
            g.setShadow(offset: .zero, blur: 26 * scale,
                        color: UIColor(red: 1.0, green: 0.87, blue: 0.67, alpha: 0.55).cgColor)
            UIColor.white.setFill()
            UIBezierPath(roundedRect: card, cornerRadius: 8 * scale).fill()
            g.setShadow(offset: .zero, blur: 0, color: nil)
            art.draw(in: card.insetBy(dx: inset, dy: inset))
        }
        return image.pngData() ?? Data()
    }

    /// Rendered wordmark for the pass header: prominent "UCB" with a small,
    /// letter-spaced subtitle beneath it.
    private static func logoPNG(scale: CGFloat, subtitle: String) -> Data {
        let size = CGSize(width: 160 * scale, height: 50 * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { _ in
            NSAttributedString(string: "UCB", attributes: [
                .font: UIFont.systemFont(ofSize: 30 * scale, weight: .heavy),
                .foregroundColor: UIColor(red: 235 / 255, green: 75 / 255, blue: 95 / 255, alpha: 1),
            ]).draw(at: CGPoint(x: 0, y: 0))
            NSAttributedString(string: subtitle, attributes: [
                .font: UIFont.systemFont(ofSize: 10 * scale, weight: .semibold),
                .foregroundColor: UIColor.white.withAlphaComponent(0.9),
                .kern: 2.4 * scale,
            ]).draw(at: CGPoint(x: 1.5 * scale, y: 37 * scale))
        }
        return image.pngData() ?? Data()
    }
}

// MARK: - Minimal store-only ZIP writer (the .pkpass container)

private enum ZipWriter {
    static func archive(files: [String: Data]) -> Data {
        var out = Data()
        var central = Data()
        var entryCount: UInt16 = 0

        for (name, data) in files.sorted(by: { $0.key < $1.key }) {
            let nameBytes = Data(name.utf8)
            let crc = crc32(data)
            let offset = UInt32(out.count)

            // Local file header
            out.append(le32(0x04034B50))
            out.append(le16(20)); out.append(le16(0)); out.append(le16(0))   // version, flags, method=store
            out.append(le16(0)); out.append(le16(0))                          // time, date
            out.append(le32(crc))
            out.append(le32(UInt32(data.count))); out.append(le32(UInt32(data.count)))
            out.append(le16(UInt16(nameBytes.count))); out.append(le16(0))
            out.append(nameBytes)
            out.append(data)

            // Central directory record
            central.append(le32(0x02014B50))
            central.append(le16(20)); central.append(le16(20)); central.append(le16(0)); central.append(le16(0))
            central.append(le16(0)); central.append(le16(0))
            central.append(le32(crc))
            central.append(le32(UInt32(data.count))); central.append(le32(UInt32(data.count)))
            central.append(le16(UInt16(nameBytes.count))); central.append(le16(0)); central.append(le16(0))
            central.append(le16(0)); central.append(le16(0))
            central.append(le32(0)); central.append(le32(offset))
            central.append(nameBytes)
            entryCount += 1
        }

        let centralOffset = UInt32(out.count)
        out.append(central)
        // End of central directory
        out.append(le32(0x06054B50))
        out.append(le16(0)); out.append(le16(0))
        out.append(le16(entryCount)); out.append(le16(entryCount))
        out.append(le32(UInt32(central.count))); out.append(le32(centralOffset))
        out.append(le16(0))
        return out
    }

    private static func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    private static func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

    private static let crcTable: [UInt32] = (0..<256).map { i in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }
}
