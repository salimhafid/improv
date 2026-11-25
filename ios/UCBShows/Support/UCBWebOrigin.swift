import Foundation

enum UCBWebOrigin {
    static func isTrusted(_ url: URL?) -> Bool {
        guard let url, let origin = URLComponents(url: url, resolvingAgainstBaseURL: true),
              origin.scheme?.lowercased() == "https", origin.user == nil, origin.password == nil,
              origin.rangeOfPort == nil || origin.port == 443 else { return false }
        switch origin.percentEncodedHost?.lowercased() {
        case "ucbcomedy.com", "www.ucbcomedy.com": return true
        default: return false
        }
    }
}
