# Wallet pass signing

Drop two PEM files here to enable the "Add to Apple Wallet" button for the
UCB Student ID (they are git-ignored — never commit them):

    pass_cert.pem   the Pass Type ID certificate
    pass_key.pem    its private key (PKCS#8)

## One-time setup (Apple Developer portal)

1. Certificates, Identifiers & Profiles → Identifiers → + → **Pass Type IDs**
   → e.g. `pass.com.salimhafid.UCBShows.studentid`.
2. Certificates → + → **Pass Type ID Certificate**, pick that identifier.
   Create the CSR in Keychain Access (Certificate Assistant → Request a
   Certificate), upload it, download `pass.cer`, double-click to install.
3. In Keychain Access, export the certificate + key as `pass.p12`, then:

       openssl pkcs12 -in pass.p12 -clcerts -nokeys -legacy | openssl x509 -out pass_cert.pem
       openssl pkcs12 -in pass.p12 -nocerts -nodes -legacy | openssl pkcs8 -topk8 -nocrypt -out pass_key.pem

4. Put both files in this folder and rebuild. The pass type identifier and
   team id are read from the certificate itself — no other config.

`wwdr_g4.pem` is Apple's public WWDR G4 intermediate (expires 2030) and is
committed. Passes are signed ON DEVICE; if you ever ship this to the App
Store, remember the key ships inside the binary — an extractor could sign
cosmetic passes under this pass type id (no payment/identity risk, but
rotate the certificate if that ever matters).
