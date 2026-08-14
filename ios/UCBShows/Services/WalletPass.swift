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
            case .qrUndecodable: return "Couldn’t read the Student ID QR payload."
            case .signingFailed: return "Couldn’t sign the Wallet pass."
            }
        }
    }

    /// Build the signed .pkpass for the Student ID ticket.
    @MainActor
    static func studentIDPass(ticket: Ticket) async throws -> PKPass {
        guard let identity = signingIdentity() else { throw BuildError.noSigningIdentity }
        guard ticket.kind == .studentID,
              let image = await QRRender.cachedImage(svg: ticket.qrSVG),
              let payload = decodeQRPayload(image) else { throw BuildError.qrUndecodable }

        let passJSON = passJSON(identity: identity, ticket: ticket, payload: payload)

        var files: [String: Data] = ["pass.json": passJSON]
        for (name, side) in [("icon.png", 29.0), ("icon@2x.png", 58.0), ("icon@3x.png", 87.0)] {
            files[name] = iconPNG(side: side)
        }
        for (name, side) in [("thumbnail.png", 90.0), ("thumbnail@2x.png", 180.0), ("thumbnail@3x.png", 270.0)] {
            files[name] = thumbnailPNG(side: side)
        }
        for (name, scale) in [("logo.png", 1.0), ("logo@2x.png", 2.0), ("logo@3x.png", 3.0)] {
            files[name] = logoPNG(scale: scale)
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

    private static func passJSON(identity: SigningIdentity, ticket: Ticket, payload: String) -> Data {
        let serial = SHA256.hash(data: Data(payload.utf8)).prefix(12)
            .map { String(format: "%02x", $0) }.joined()
        // Wallet surfaces the pass on the lock screen near these coordinates.
        let locations: [[String: Any]] = Venue.all.map {
            ["latitude": $0.latitude, "longitude": $0.longitude,
             "relevantText": "You’re near \($0.name) — show your UCB Student ID at the door."]
        }
        // Minimal near-black card: the rendered logo (big UCB, small STUDENT ID
        // beneath) top left, the skull tile top right, the QR below. No fields,
        // no barcode caption — Wallet renders the QR at its own fixed size.
        let pass: [String: Any] = [
            "formatVersion": 1,
            "passTypeIdentifier": identity.passTypeIdentifier,
            "teamIdentifier": identity.teamIdentifier,
            "serialNumber": "ucb-student-id-\(serial)",
            "organizationName": "Improv",
            "description": "UCB Student ID",
            "foregroundColor": "rgb(255,255,255)",
            "backgroundColor": "rgb(17,17,20)",
            "labelColor": "rgb(235,75,95)",
            "barcodes": [[
                "format": "PKBarcodeFormatQR",
                "message": payload,
                "messageEncoding": "iso-8859-1",
            ]],
            "locations": locations,
            "maxDistance": 300,
            "generic": ["primaryFields": [[String: Any]]()],
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

    /// Rendered wordmark for the pass header: prominent "UCB" with a small,
    /// letter-spaced "STUDENT ID" beneath it.
    private static func logoPNG(scale: CGFloat) -> Data {
        let size = CGSize(width: 160 * scale, height: 50 * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { _ in
            NSAttributedString(string: "UCB", attributes: [
                .font: UIFont.systemFont(ofSize: 30 * scale, weight: .heavy),
                .foregroundColor: UIColor(red: 235 / 255, green: 75 / 255, blue: 95 / 255, alpha: 1),
            ]).draw(at: CGPoint(x: 0, y: 0))
            NSAttributedString(string: "STUDENT ID", attributes: [
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
