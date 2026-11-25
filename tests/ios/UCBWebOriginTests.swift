import Foundation

enum UCBWebOriginTests {
    static func run() {
        let trusted = [
            "https://ucbcomedy.com/course/improv-101/1001/",
            "https://www.ucbcomedy.com/my-account/",
            "HTTPS://UCBComedy.COM:443/events/"
        ]
        let external = [
            "http://ucbcomedy.com/classes/",
            "https://ucbcomedy.com:8443/",
            "https://ucbcomedy.com:99999999999999999999999999/",
            "https://ucbcomedy.com.example.org/",
            "https://tickets.ucbcomedy.com/",
            "https://notucbcomedy.com/",
            "https://example.org/?return=https://ucbcomedy.com",
            "https://ucbcomedy.com@example.org/",
            "https://username@ucbcomedy.com/",
            "https://username:password@www.ucbcomedy.com/",
            "https://brooklyncomedy.com/",
            "mailto:boxoffice@ucbcomedy.com",
            "/my-account/"
        ]
        for link in trusted {
            precondition(UCBWebOrigin.isTrusted(URL(string: link)), "Expected UCB browser for \(link)")
        }
        for link in external {
            precondition(!UCBWebOrigin.isTrusted(URL(string: link)), "Expected external handling for \(link)")
        }
        precondition(!UCBWebOrigin.isTrusted(nil))
        print("UCB browser routing tests passed")
    }
}
