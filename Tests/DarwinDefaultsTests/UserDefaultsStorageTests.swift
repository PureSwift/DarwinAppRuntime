import Foundation
import Testing
@testable import DarwinDefaults

/// The store over a real `UserDefaults` suite, one per test, removed after.
@Suite("UserDefaults storage")
final class UserDefaultsStorageTests {

    let suite = "org.pureswift.DarwinDefaultsTests.\(UUID().uuidString)"

    let storage: UserDefaultsStorage

    init() throws {
        storage = try #require(UserDefaultsStorage(suite: suite, maximumValueSize: 16))
    }

    deinit {
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    @Test func valuesComeBack() {
        #expect(storage.string("name") == nil)
        #expect(storage.setString("Ada", key: "name"))
        #expect(storage.setString("", key: "empty"))
        #expect(storage.setData([0, 1, 255], key: "bytes"))
        #expect(storage.string("name") == "Ada")
        #expect(storage.string("empty") == "", "an empty string is a value")
        #expect(storage.data("bytes") == [0, 1, 255])
        #expect(Set(storage.keys()) == ["name", "empty", "bytes"])
    }

    @Test func aKeyHoldsOneValue() {
        #expect(storage.setString("text", key: "k"))
        #expect(storage.setData([7], key: "k"))
        #expect(storage.string("k") == nil)
        #expect(storage.data("k") == [7])
        #expect(storage.setString("again", key: "k"))
        #expect(storage.data("k") == nil)
        #expect(storage.keys() == ["k"])
    }

    @Test func aValueTooLargeIsRefused() {
        #expect(storage.setString("small", key: "k"))
        #expect(!storage.setString(String(repeating: "x", count: 17), key: "k"))
        #expect(!storage.setData(Array(repeating: 0, count: 17), key: "k"))
        #expect(storage.string("k") == "small", "the old value stays")
        #expect(storage.setString(String(repeating: "é", count: 8), key: "k"), "16 bytes of UTF-8")
    }

    @Test func removing() {
        #expect(storage.setString("v", key: "k"))
        storage.remove("k")
        storage.remove("never set")
        #expect(storage.string("k") == nil)
        #expect(storage.keys().isEmpty)
    }

    @Test func onlyTheAppsOwnValues() throws {
        // The global domain is in every suite's search list.
        let defaults = try #require(UserDefaults(suiteName: suite))
        #expect(defaults.object(forKey: "AppleLanguages") != nil)
        #expect(storage.string("AppleLanguages") == nil)
        #expect(storage.data("AppleLanguages") == nil)
        #expect(!storage.keys().contains("AppleLanguages"))
        #expect(UserDefaults.standard.persistentDomain(forName: suite) == nil, "nothing set yet")
    }

    @Test func anotherKindReadsAsMissing() throws {
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(42, forKey: "count")
        #expect(storage.string("count") == nil)
        #expect(storage.data("count") == nil)
    }

    @Test func anotherStoreOnTheSuiteSeesTheValues() throws {
        #expect(storage.setString("kept", key: "k"))
        let other = try #require(UserDefaultsStorage(suite: suite))
        #expect(other.string("k") == "kept")
        #expect(UserDefaults.standard.persistentDomain(forName: suite)?["k"] as? String == "kept")
    }

    @Test func theSuiteIsNamedForTheApp() {
        #expect(UserDefaultsStorage.suite(for: .main).hasSuffix(".defaults"))
        #expect(UserDefaultsStorage.suite(for: .main) != Bundle.main.bundleIdentifier)
    }
}
