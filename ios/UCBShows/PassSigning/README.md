# Wallet pass signing

Drop two PEM files here to enable the "Add to Apple Wallet" button. One
identity signs every pass the app builds — the UCB Student ID (store card,
relevant near both theaters) and each reserved show ticket (event ticket,
relevant at its venue around showtime). The files are git-ignored — never
commit them:

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

   `-legacy` is an OpenSSL 3 flag (it enables the RC2 cipher older Keychain
   exports use). The `openssl` that ships with macOS is LibreSSL, which
   rejects it with "unknown option" — install OpenSSL 3 (`brew install
   openssl@3`) and run that binary, or drop the flag if your `.p12` was
   exported with AES (recent macOS versions) and the commands succeed
   without it.

4. Put both files in this folder and rebuild. The pass type identifier and
   team id are read from the certificate itself — no other config.

## Alternative: issue the certificate from the CLI (what was done 2026-09-07)

No Keychain Access, no `.p12`: generate the key and CSR here, then have the
App Store Connect API issue the certificate against the existing Pass Type
ID. Needs an ASC API key with the **Admin** role (a Developer-role key gets
HTTP 403 on certificate creation).

    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out pass_key.pem
    openssl req -new -key pass_key.pem -subj "/CN=Improv Pass Signing/OU=8FKP6A38FJ/O=Salim Hafid/C=US" -out /tmp/pass.csr
    ASC_ISSUER_ID=… ASC_KEY_ID=… ASC_KEY_PATH=~/.appstoreconnect/private_keys/AuthKey_….p8 \
      python3 ../../../tools/asc_pass_cert.py whoami                      # lists pass type ids + certs
    … asc_pass_cert.py create-cert <passTypeId resource id> /tmp/pass.csr pass_cert.pem

The certificate Apple returns already carries `UID` = pass type id and
`OU` = team, which is all `WalletPass.signingIdentity` reads. Verify the pair
with `openssl x509 -in pass_cert.pem -noout -modulus | openssl md5` versus
`openssl pkey -in pass_key.pem -pubout | openssl rsa -pubin -noout -modulus | openssl md5`.

`wwdr_g4.pem` is Apple's public WWDR G4 intermediate (expires 2030) and is
committed. Passes are signed ON DEVICE; if you ever ship this to the App
Store, remember the key ships inside the binary — an extractor could sign
cosmetic passes under this pass type id (no payment/identity risk, but
rotate the certificate if that ever matters).
