import CoreModel
import DynamicCoreModel
import Foundation
import RuntimeCoreModel
import RuntimeNative
import Testing
@testable import DarwinModelStore

/// The module: a guest's `RuntimeModelStorage`, over the contracts and
/// AppRuntime's `HostModelStore`, on the Core Data stores. What a request
/// returns is checked against CoreModel's own evaluator, the contract's
/// reference.
///
/// Serialized, and on the main actor: the provider and the native runtime
/// are shared, and the guest's calls and the host's answers share a
/// thread, as they do in the app.
@MainActor @Suite("Model store", .serialized)
final class DarwinModelStoreTests {

    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("DarwinModelStoreTests-" + UUID().uuidString, isDirectory: true)

    init() {
        let path = directory.path
        DarwinModelStore.directory = { path }
        // This code is the host's own guest, as the host's SwiftUI player
        // is: its calls go straight to the runtime, not through an app's
        // exports.
        let native = NativeRuntime.shared
        native.bindDirectly()
        native.capabilities = nil
        DarwinModelStore.register(in: native)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    static let model = Model(entities: [
        EntityDescription(id: "Person", attributes: [
            Attribute(id: "name", type: .string),
            Attribute(id: "age", type: .int32),
            Attribute(id: "score", type: .double),
            Attribute(id: "isMember", type: .bool),
            Attribute(id: "joined", type: .date),
            Attribute(id: "token", type: .uuid),
            Attribute(id: "homepage", type: .url),
            Attribute(id: "balance", type: .decimal),
            Attribute(id: "photo", type: .data),
            Attribute(id: "rank", type: .int16),
            Attribute(id: "visits", type: .int64),
            Attribute(id: "ratio", type: .float),
        ], relationships: [
            Relationship(id: "team", type: .toOne, destinationEntity: "Team", inverseRelationship: "members"),
        ]),
        EntityDescription(id: "Team", attributes: [
            Attribute(id: "name", type: .string),
        ], relationships: [
            Relationship(id: "members", type: .toMany, destinationEntity: "Person", inverseRelationship: "team"),
        ]),
    ])

    static func person(_ id: ObjectID, _ name: String, age: Int32, score: Double = 0, isMember: Bool = false, team: ObjectID? = nil) -> ModelData {
        var data = ModelData(entity: "Person", id: id)
        data.attributes["name"] = .string(name)
        data.attributes["age"] = .int32(age)
        data.attributes["score"] = .double(score)
        data.attributes["isMember"] = .bool(isMember)
        if let team {
            data.relationships["team"] = .toOne(team)
        }
        return data
    }

    static let records: [ModelData] = {
        var ada = person("ada", "Ada", age: 36, score: 9.5, isMember: true, team: "engine")
        ada.attributes["joined"] = .date(Date(timeIntervalSince1970: 1_700_000_000.5))
        ada.attributes["token"] = .uuid(UUID(uuidString: "9E3C1A52-0C1B-4F0E-9D4B-6A1F2C3D4E5F")!)
        ada.attributes["homepage"] = .url(URL(string: "https://example.com/ada?x=1")!)
        ada.attributes["balance"] = .decimal(Decimal(string: "1234.5678")!)
        ada.attributes["photo"] = .data(Data([0, 1, 2, 255]))
        ada.attributes["rank"] = .int16(-3)
        ada.attributes["visits"] = .int64(1 << 40)
        ada.attributes["ratio"] = .float(0.25)
        var engine = ModelData(entity: "Team", id: "engine")
        engine.attributes["name"] = .string("Engine")
        var theory = ModelData(entity: "Team", id: "theory")
        theory.attributes["name"] = .string("Theory")
        return [
            engine, theory, ada,
            person("grace", "Grace", age: 45, score: 8, isMember: true, team: "engine"),
            person("alan", "alan", age: 41, score: 7.25, team: "theory"),
            person("edsger", "Édsger", age: 17, score: 0),
            person("linus", "Linus", age: 17, score: 3, isMember: true, team: "theory"),
        ]
    }()

    func open(_ name: String = "people") async throws -> RuntimeModelStorage {
        let store = try await RuntimeModelStorage.open(name, model: Self.model)
        var changes = ModelChanges()
        for record in Self.records {
            changes.insert(record)
        }
        try await store.perform(changes)
        return store
    }

    @Test func moduleListsTheContracts() {
        let names = DarwinModelStore.contracts.map(\.name)
        #expect(names.contains("org.pureswift.data.ModelStore"))
        #expect(names.count == HostModelStoreModule.contracts.count)
    }

    @Test func valuesComeBackAsTheyWent() async throws {
        let store = try await open()
        let ada = try #require(try await store.fetch("Person", for: "ada"))
        let sent = Self.records[2]
        for (key, value) in sent.attributes {
            #expect(ada.attributes[key] == value, "\(key)")
        }
        #expect(ada.relationships["team"] == .toOne("engine"))
        let edsger = try #require(try await store.fetch("Person", for: "edsger"))
        #expect(edsger.attributes["joined"] == .null)
        #expect(edsger.relationships["team"] == .null)
    }

    @Test func requestsMatchTheReference() async throws {
        let store = try await open()
        let reference = InMemoryModelStorage(model: Self.model)
        try await reference.insert(Self.records)

        typealias Predicate = FetchRequest.Predicate
        func compare(_ key: PropertyKey, _ type: Predicate.Comparison.Operator, _ value: AttributeValue, _ options: Set<Predicate.Comparison.Option> = []) -> Predicate {
            .comparison(.init(left: .keyPath(.init(rawValue: key.rawValue)), right: .attribute(value), type: type, options: options))
        }
        let predicates: [Predicate?] = [
            nil,
            .value(true),
            .value(false),
            compare("age", .greaterThanOrEqualTo, .int32(18)),
            compare("age", .lessThan, .int32(18)),
            compare("age", .equalTo, .int32(17)),
            compare("age", .notEqualTo, .int32(17)),
            compare("score", .greaterThan, .double(7.5)),
            compare("isMember", .equalTo, .bool(true)),
            compare("name", .equalTo, .string("alan")),
            compare("name", .beginsWith, .string("a")),
            compare("name", .beginsWith, .string("a"), [.caseInsensitive]),
            compare("name", .endsWith, .string("N"), [.caseInsensitive]),
            compare("name", .like, .string("*a*")),
            compare("joined", .equalTo, .null),
            compare("joined", .greaterThan, .date(Date(timeIntervalSince1970: 1_600_000_000))),
            compare("token", .equalTo, .uuid(UUID(uuidString: "9E3C1A52-0C1B-4F0E-9D4B-6A1F2C3D4E5F")!)),
            compare("photo", .equalTo, .data(Data([0, 1, 2, 255]))),
            compare("visits", .equalTo, .int64(1 << 40)),
            compare("team.name", .equalTo, .string("Theory")),
            .comparison(.init(left: .keyPath("team"), right: .relationship(.toOne("engine")), type: .equalTo)),
            .comparison(.init(left: .keyPath("team"), right: .relationship(.null), type: .equalTo)),
            .comparison(.init(left: .arithmetic(.init(function: .add, left: .keyPath("age"), right: .attribute(.int32(4)))), right: .attribute(.int32(45)), type: .equalTo)),
            .compound(.and([compare("age", .greaterThanOrEqualTo, .int32(18)), compare("isMember", .equalTo, .bool(true))])),
            .compound(.or([compare("age", .lessThan, .int32(18)), compare("name", .equalTo, .string("Ada"))])),
            .compound(.not(compare("isMember", .equalTo, .bool(true)))),
            .compound(.and([])),
            .compound(.or([])),
        ]
        // Sorts that leave no ties: Core Data's order among equals isn't the
        // reference's.
        let sorts: [[FetchRequest.SortDescriptor]] = [
            [.init(property: "name")],
            [.init(property: "age"), .init(property: "score", ascending: false)],
            [.init(property: "joined", ascending: false), .init(property: "name")],
        ]
        var mismatches = [String]()
        for predicate in predicates {
            // Unsorted, what's found, in any order.
            let all = FetchRequest(entity: "Person", predicate: predicate)
            let expected = Set(try await reference.fetchID(all))
            let found = Set(try await store.fetchID(all))
            let count = try await store.count(all)
            if found != expected || count != UInt(expected.count) {
                mismatches.append("\(String(describing: predicate)): \(found) \(count), expected \(expected)")
            }
            for sort in sorts {
                for (limit, offset) in [(0, 0), (2, 0), (2, 1)] {
                    let request = FetchRequest(entity: "Person", sortDescriptors: sort, predicate: predicate, fetchLimit: limit, fetchOffset: offset)
                    let expected = try await reference.fetch(request).map(\.id)
                    let found = try await store.fetch(request).map(\.id)
                    let ids = try await store.fetchID(request)
                    let count = try await store.count(request)
                    if found != expected || ids != expected || count != UInt(expected.count) {
                        mismatches.append("\(String(describing: predicate)) \(sort) \(limit) \(offset): \(found) \(ids) \(count), expected \(expected)")
                    }
                }
            }
        }
        #expect(mismatches.isEmpty, "\(mismatches.joined(separator: "\n"))")

        // Where CoreModel's evaluator is wrong, the store is right:
        // - its substring search steps through the pattern with the subject's
        //   indices, so after the two bytes of "É" it finds "ra" in "Édsger";
        // - it doesn't read `[d]`.
        let containsRA = compare("name", .contains, .string("ra"))
        #expect(try await reference.fetchID(FetchRequest(entity: "Person", predicate: containsRA)) == ["edsger", "grace"])
        #expect(try await store.fetchID(FetchRequest(entity: "Person", predicate: containsRA)) == ["grace"])
        let beginsWithE = compare("name", .beginsWith, .string("e"), [.caseInsensitive, .diacriticInsensitive])
        #expect(try await reference.fetchID(FetchRequest(entity: "Person", predicate: beginsWithE)) == [])
        #expect(try await store.fetchID(FetchRequest(entity: "Person", predicate: beginsWithE)) == ["edsger"])
        #expect(try await store.count(FetchRequest(entity: "Person", predicate: compare("age", .greaterThanOrEqualTo, .int32(18)))) == 3)

        let members: Predicate = .comparison(.init(left: .keyPath("members"), right: .relationship(.toOne("linus")), type: .contains))
        #expect(try await store.fetchID(FetchRequest(entity: "Team", predicate: members)) == ["theory"])
        let anyMember: Predicate = .comparison(.init(left: .keyPath("members.age"), right: .attribute(.int32(40)), type: .greaterThan, modifier: .any))
        #expect(try await store.fetchID(FetchRequest(entity: "Team", predicate: anyMember)) == (try await reference.fetchID(FetchRequest(entity: "Team", predicate: anyMember))))
    }

    @Test func aStoreKeepsItsObjectsAcrossLaunches() async throws {
        _ = try await open("kept")
        // A new launch: a new provider over the same directory.
        DarwinModelStore.configure()
        let again = try await RuntimeModelStorage.open("kept", model: Self.model)
        #expect(try await again.count(FetchRequest(entity: "Person")) == 5)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("kept/Store.sqlite").path))

        try await RuntimeModelStorage.destroy("kept")
        let fresh = try await RuntimeModelStorage.open("kept", model: Self.model)
        #expect(try await fresh.count(FetchRequest(entity: "Person")) == 0)
    }

    @Test func aChangedModelIsRefusedThroughTheContract() async throws {
        _ = try await open("typed")
        var retyped = Self.model
        retyped.entities[0].attributes.removeAll { $0.id == "age" }
        retyped.entities[0].attributes.append(Attribute(id: "age", type: .string))
        do {
            _ = try await RuntimeModelStorage.open("typed", model: retyped)
            Issue.record("opened")
        } catch {
            #expect(error.code == .migrationRequired)
        }
        let emptied = try await RuntimeModelStorage.open("typed", model: retyped, migration: .reset)
        #expect(try await emptied.count(FetchRequest(entity: "Person")) == 0)
    }
}
