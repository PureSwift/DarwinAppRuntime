import AuthenticationServices
import DynamicAuthentication
import DynamicSecrets
import Foundation
import RuntimeAuthentication
import RuntimeSecrets
import Security
import Testing
@testable import DarwinAuthentication
@testable import DarwinSecrets

/// The Keychain, under a service of the tests' own, which they empty: the
/// user's own items are left alone.
@Suite("Keychain", .serialized)
struct KeychainTests {

    let service = "org.pureswift.DarwinSecretsTests.\(UUID().uuidString)"

    func store(marker: String? = nil) -> KeychainStore {
        KeychainStore(service: service, marker: marker)
    }

    @Test func keepsSecretsByKey() throws {
        let keychain = store()
        defer { try? keychain.removeAll() }
        #expect(try keychain.value(forKey: "token") == nil)
        try keychain.set("token", value: Array("abc".utf8), accessibility: .afterFirstUnlock)
        try keychain.set("password", value: [0, 255, 7], accessibility: .whenUnlocked)
        #expect(try keychain.value(forKey: "token") == Array("abc".utf8))
        #expect(try keychain.value(forKey: "password") == [0, 255, 7])
        // Replaced whole.
        try keychain.set("token", value: Array("xyz".utf8), accessibility: .whenUnlocked)
        #expect(try keychain.value(forKey: "token") == Array("xyz".utf8))
        #expect(try keychain.keys().sorted() == ["password", "token"])
        // No secret is no error.
        try keychain.remove("token")
        try keychain.remove("token")
        #expect(try keychain.value(forKey: "token") == nil)
        try keychain.removeAll()
        #expect(try keychain.keys().isEmpty)
    }

    @Test func emptiesTheStoreOnTheFirstRunSinceInstalling() throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("secrets-installed-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: marker) }
        // A secret left from before the app was removed.
        let before = store()
        try before.set("old", value: [1], accessibility: .whenUnlocked)
        let installed = store(marker: marker)
        defer { try? installed.removeAll() }
        #expect(try installed.value(forKey: "old") == nil)
        #expect(FileManager.default.fileExists(atPath: marker))
        // Not on the runs after.
        try installed.set("new", value: [2], accessibility: .whenUnlocked)
        let again = store(marker: marker)
        #expect(try again.value(forKey: "new") == [2])
    }

    @Test func saysWhyItFailed() {
        #expect(KeychainStore.error(errSecInteractionNotAllowed) == .unavailable)
        #expect(KeychainStore.error(errSecUserCanceled) == .notAllowed)
        #expect(KeychainStore.error(errSecAuthFailed) == .notAllowed)
        #expect(KeychainStore.accessible(.whenUnlocked) == kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
        #expect(KeychainStore.accessible(.afterFirstUnlock) == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
    }
}

/// `HostSecrets` over the Keychain, as the guest calls it.
@Suite("Secrets", .serialized)
@MainActor
struct SecretsTests {

    final class Answer: SecretCallback {
        var completed = false
        var value: [UInt8]??
        var keys: [String]?
        var failure: KeychainError?
        var answered: Bool { completed || value != nil || keys != nil || failure != nil }
        func didComplete() { completed = true }
        func didGet(_ value: [UInt8], found: Bool) { self.value = .some(found ? value : nil) }
        func didList(_ keys: [String]) { self.keys = keys }
        func didFail(_ error: Int32) { failure = KeychainError(rawValue: error) }
    }

    func answer(_ call: (Answer) -> Void) async throws -> Answer {
        let answer = Answer()
        call(answer)
        let deadline = Date().addingTimeInterval(5)
        while !answer.answered {
            guard Date() < deadline else {
                Issue.record("no answer")
                break
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        return answer
    }

    @Test func keepsTheGuestsSecrets() async throws {
        HostSecrets.reset()
        let store = KeychainStore(service: "org.pureswift.DarwinSecretsTests.\(UUID().uuidString)", marker: nil)
        HostSecrets.store = store
        defer {
            try? store.removeAll()
            HostSecrets.reset()
        }
        let secrets = HostSecrets.shared()
        #expect(try await answer { secrets.set("b.token", value: Array("t".utf8), accessibility: 1, callback: $0) }.completed)
        #expect(try await answer { secrets.set("a.password", value: Array("p".utf8), accessibility: 0, callback: $0) }.completed)
        #expect(try await answer { secrets.get("b.token", callback: $0) }.value == .some(Array("t".utf8)))
        #expect(try await answer { secrets.get("missing", callback: $0) }.value == .some(nil))
        #expect(try await answer { secrets.keys($0) }.keys == ["a.password", "b.token"])
        #expect(try await answer { secrets.set("", value: [1], accessibility: 0, callback: $0) }.failure == .invalidKey)
        #expect(try await answer { secrets.removeAll($0) }.completed)
        #expect(try await answer { secrets.keys($0) }.keys == [])
    }
}

/// The sign-in page's parts that need no window.
@Suite("Sign-in")
@MainActor
struct SignInTests {

    @Test func readsTheManifestsSchemes() {
        let info: [String: Any] = ["RTAuthenticationSchemes": ["com.example.mail", "com.example.other"]]
        #expect(DarwinAuthentication.declaredSchemes(info) == ["com.example.mail", "com.example.other"])
        #expect(DarwinAuthentication.declaredSchemes([:]).isEmpty)
    }

    @Test func callsBackOnTheRedirectsScheme() {
        #expect(SystemBrowser.scheme(of: "com.example.mail:/oauth") == "com.example.mail")
        #expect(SystemBrowser.scheme(of: "no-scheme") == nil)
        #expect(SystemBrowser.scheme(of: ":/oauth") == nil)
    }

    @Test func saysHowItEnded() throws {
        let url = try #require(URL(string: "com.example.mail:/oauth?code=1&state=2"))
        #expect(SystemBrowser.result(url, nil) == .success("com.example.mail:/oauth?code=1&state=2"))
        let cancelled = ASWebAuthenticationSessionError(.canceledLogin)
        #expect(SystemBrowser.result(nil, cancelled) == .failure(.canceledLogin))
        let noWindow = ASWebAuthenticationSessionError(.presentationContextNotProvided)
        #expect(SystemBrowser.result(nil, noWindow) == .failure(.notAllowed))
        #expect(SystemBrowser.result(nil, nil) == .failure(.unknown))
    }

    @Test func refusesWhatIsntDeclared() async throws {
        HostWebAuthentication.reset()
        HostWebAuthentication.presenter = SystemBrowser()
        HostWebAuthentication.declaredSchemes = ["com.example.mail"]
        defer { HostWebAuthentication.reset() }
        let authentication = HostWebAuthentication.shared()
        #expect(authentication.redirectURL("com.example.mail", path: "/oauth") == "com.example.mail:/oauth")

        final class Answer: WebAuthenticationCallback {
            var failure: WebAuthenticationError?
            func didAuthenticate(_ url: String) { }
            func didFail(_ error: Int32) { failure = WebAuthenticationError(rawValue: error) }
        }
        let undeclared = Answer()
        authentication.authenticate("https://id.example.com/", redirect: "com.example.other:/oauth", ephemeral: false, callback: undeclared)
        let plain = Answer()
        authentication.authenticate("http://id.example.com/", redirect: "com.example.mail:/oauth", ephemeral: false, callback: plain)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(undeclared.failure == .invalidURL)
        #expect(plain.failure == .invalidURL)
        #expect(!authentication.isShowing)
    }
}
