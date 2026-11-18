import CoreData
import CoreModel
import DynamicCoreModel
import Foundation
import RuntimeCoreModel
import Testing
@testable import DarwinModelStore

/// The provider and its stores on real SQLite files, in a directory of
/// the test's own, removed after.
@Suite("Core Data stores")
final class CoreDataStoresTests {

    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("DarwinModelStoreTests-" + UUID().uuidString, isDirectory: true)

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    /// The provider as a launch of the app makes it.
    func launch() -> CoreDataStores {
        CoreDataStores(directory: directory.path)
    }

    static let model = Model(entities: [
        EntityDescription(id: "Person", attributes: [
            Attribute(id: "name", type: .string),
            Attribute(id: "age", type: .int32),
            Attribute(id: "photo", type: .data),
        ], relationships: [
            Relationship(id: "team", type: .toOne, destinationEntity: "Team", inverseRelationship: "members"),
        ]),
        EntityDescription(id: "Team", attributes: [
            Attribute(id: "name", type: .string),
        ], relationships: [
            Relationship(id: "members", type: .toMany, destinationEntity: "Person", inverseRelationship: "team"),
        ]),
        EntityDescription(id: "Note", attributes: [Attribute(id: "text", type: .string)], relationships: []),
    ])

    static func person(_ id: ObjectID, _ name: String, age: Int32, team: ObjectID? = nil) -> ModelData {
        var data = ModelData(entity: "Person", id: id)
        data.attributes["name"] = .string(name)
        data.attributes["age"] = .int32(age)
        data.relationships["team"] = team.map { .toOne($0) } ?? .null
        return data
    }

    static func team(_ id: ObjectID, _ name: String) -> ModelData {
        var data = ModelData(entity: "Team", id: id)
        data.attributes["name"] = .string(name)
        return data
    }

    func open(_ provider: CoreDataStores, _ model: Model = CoreDataStoresTests.model, indexes: [EntityName: [[PropertyKey]]] = [:], migration: ModelMigration = .fail) async throws -> any ModelStorage {
        try await provider.open("library", model: model, indexes: indexes, migration: migration)
    }

    func fill(_ store: any ModelStorage) async throws {
        try await store.insert([
            Self.team("engine", "Engine"),
            Self.team("theory", "Theory"),
            Self.person("grace", "Grace", age: 45, team: "engine"),
            Self.person("ada", "Ada", age: 36, team: "engine"),
            Self.person("linus", "Linus", age: 17, team: "theory"),
            Self.person("alan", "Alan", age: 41),
        ])
    }

    /// What a failing call failed with; `nil` when it didn't.
    func failure(_ body: () async throws -> Void) async -> ModelStoreError.Code? {
        do {
            try await body()
            return nil
        } catch {
            return (error as? ModelStoreError)?.code
        }
    }

    // MARK: Keeping

    @Test func aStoreIsAFileThatOutlivesTheLaunch() async throws {
        do {
            let store = try await open(launch())
            try await fill(store)
        }
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("library/Store.sqlite").path))

        let store = try await open(launch())
        #expect(try await store.count(FetchRequest(entity: "Person")) == 4)
        let ada = try #require(try await store.fetch("Person", for: "ada"))
        #expect(ada.attributes["name"] == .string("Ada"))
        #expect(ada.attributes["age"] == .int32(36))
        #expect(ada.attributes["photo"] == .null)
        #expect(ada.relationships["team"] == .toOne("engine"))
    }

    @Test func openingAgainSharesTheStore() async throws {
        let provider = launch()
        let first = try await open(provider)
        let second = try await open(provider)
        #expect(first === second)
    }

    @Test func destroyingRemovesTheFiles() async throws {
        let provider = launch()
        try await fill(try await open(provider))
        try await provider.destroy("library")
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("library").path))
        try await provider.destroy("never-made")
        #expect(try await open(provider).count(FetchRequest(entity: "Person")) == 0)
    }

    @Test func aStoreOpenedWithAnotherModelLetsGoOfTheOld() async throws {
        let provider = launch()
        let before = try await open(provider)
        try await fill(before)
        var grown = Self.model
        grown.entities[2].attributes.append(Attribute(id: "title", type: .string))
        let after = try await open(provider, grown)
        #expect(after !== before)
        #expect((before as! NSPersistentContainer).persistentStoreCoordinator.persistentStores.isEmpty)
        #expect(try await after.count(FetchRequest(entity: "Person")) == 4)
    }

    // MARK: The store

    @Test func anInsertMerges() async throws {
        let store = try await open(launch())
        try await fill(store)
        var partial = ModelData(entity: "Person", id: "ada")
        partial.attributes["age"] = .int32(37)
        try await store.insert(partial)
        let ada = try #require(try await store.fetch("Person", for: "ada"))
        #expect(ada.attributes["age"] == .int32(37))
        #expect(ada.attributes["name"] == .string("Ada"), "left as it was")
        #expect(ada.relationships["team"] == .toOne("engine"))
    }

    @Test func relationshipsKeepBothSides() async throws {
        let store = try await open(launch())
        try await fill(store)
        let engine = try #require(try await store.fetch("Team", for: "engine"))
        guard case .toMany(let members) = engine.relationships["members"] else {
            Issue.record("members: \(String(describing: engine.relationships["members"]))")
            return
        }
        #expect(Set(members) == ["ada", "grace"])

        // Deleting a member takes it out of its team.
        try await store.delete("Person", for: "ada")
        let after = try #require(try await store.fetch("Team", for: "engine"))
        #expect(after.relationships["members"] == .toMany(["grace"]))
        let teamName: FetchRequest.Predicate = .comparison(.init(left: .keyPath("team.name"), right: .attribute(.string("Engine")), type: .equalTo))
        #expect(try await store.fetchID(FetchRequest(entity: "Person", predicate: teamName)) == ["grace"])
    }

    // MARK: Migration

    @Test func theStoredModelIsInTheFile() async throws {
        _ = try await open(launch(), indexes: ["Person": [["age"]]])
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            ofType: NSSQLiteStoreType, at: directory.appendingPathComponent("library/Store.sqlite"), options: nil
        )
        let stored = try #require(StoredModel(metadata: metadata))
        #expect(stored == StoredModel(model: Self.model, indexes: ["Person": [["age"]]]))
    }

    @Test func theStoredModelIgnoresOrder() {
        var shuffled = Self.model
        shuffled.entities.reverse()
        shuffled.entities[2].attributes.reverse()
        #expect(StoredModel(model: shuffled, indexes: ["Person": [["name"], ["age"]]])
            == StoredModel(model: Self.model, indexes: ["Person": [["age"], ["name"]], "Team": []]))
        #expect(StoredModel(model: Self.model, indexes: [:]) != StoredModel(model: Self.model, indexes: ["Person": [["age"]]]))
    }

    @Test func aChangedModelMigrates() async throws {
        try await fill(try await open(launch()))

        // More and fewer properties and entities: the objects stay.
        var grown = Self.model
        grown.entities[0].attributes.append(Attribute(id: "nickname", type: .string))
        grown.entities[0].attributes.removeAll { $0.id == "photo" }
        grown.entities.append(EntityDescription(id: "Tag", attributes: [Attribute(id: "text", type: .string)], relationships: []))
        grown.entities.removeAll { $0.id == "Note" }
        let store = try await open(launch(), grown, indexes: ["Person": [["name"]]])
        let ada = try #require(try await store.fetch("Person", for: "ada"))
        #expect(ada.attributes["name"] == .string("Ada"))
        #expect(ada.attributes["nickname"] == .null, "what's new reads as null")
        #expect(ada.attributes["photo"] == nil)
        #expect(ada.relationships["team"] == .toOne("engine"))
        #expect(try await store.count(FetchRequest(entity: "Tag")) == 0)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("library/Migrating.sqlite").path))

        // And again, in the same launch, back to the first model.
        let provider = launch()
        _ = try await open(provider, grown, indexes: ["Person": [["name"]]])
        let back = try await open(provider)
        #expect(try await back.count(FetchRequest(entity: "Person")) == 4)
    }

    @Test func aRetypedModelIsRefusedOrEmptiesTheStore() async throws {
        try await fill(try await open(launch()))
        var retyped = Self.model
        retyped.entities[0].attributes.removeAll { $0.id == "age" }
        retyped.entities[0].attributes.append(Attribute(id: "age", type: .string))
        #expect(await failure { _ = try await self.open(self.launch(), retyped) } == .migrationRequired)
        #expect(try await open(launch()).count(FetchRequest(entity: "Person")) == 4, "the refusal changed nothing")

        var rekinded = Self.model
        rekinded.entities[1].relationships = [Relationship(id: "members", type: .toOne, destinationEntity: "Person", inverseRelationship: "team")]
        #expect(await failure { _ = try await self.open(self.launch(), rekinded) } == .migrationRequired)

        let emptied = try await open(launch(), retyped, migration: .reset)
        #expect(try await emptied.count(FetchRequest(entity: "Person")) == 0)
        try await emptied.insert(ModelData(entity: "Person", id: "x", attributes: ["age": .string("forty")]))
        #expect(try await open(launch(), retyped).count(FetchRequest(entity: "Person")) == 1)
    }

    // MARK: Failures

    @Test func aDamagedFileIsCorrupted() async throws {
        let folder = directory.appendingPathComponent("library", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: 4096).write(to: folder.appendingPathComponent("Store.sqlite"))
        #expect(await failure { _ = try await self.open(self.launch()) } == .corrupted)
    }

    @Test func aModelCoreDataCantHoldIsInvalid() async throws {
        let empty = Model(entities: [EntityDescription(id: "Place", attributes: [Attribute(id: "address", elements: [])], relationships: [])])
        #expect(await failure { _ = try await self.open(self.launch(), empty) } == .invalidModel)
    }

    @Test func sqliteErrorsHaveTheirCodes() {
        func code(_ error: NSError) -> ModelStoreError.Code? {
            (CoreDataStores.translate(error) as? ModelStoreError)?.code
        }
        #expect(code(NSError(domain: NSCocoaErrorDomain, code: NSPersistentStoreSaveError, userInfo: [NSSQLiteErrorDomain: 13])) == .outOfSpace)
        #expect(code(NSError(domain: NSCocoaErrorDomain, code: 1, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSSQLiteErrorDomain, code: 11)])) == .corrupted)
        #expect(code(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)) == .outOfSpace)
        #expect(code(NSError(domain: NSCocoaErrorDomain, code: NSValidationMissingMandatoryPropertyError)) == nil)
    }
}
