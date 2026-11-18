import CoreData
import CoreDataModel
import CoreModel
import DynamicCoreModel
import Foundation
import RuntimeCoreModel

/// Where the Darwin host keeps the app's model stores (`HostRuntime.md`
/// §5.6): a SQLite file for each, opened as CoreModel's `CoreDataModel`
/// store, an `NSPersistentContainer`.
///
/// ```
/// <directory>/<name>/Store.sqlite   (and its -wal and -shm)
/// ```
///
/// **The stored model.** Core Data can migrate a store only from the model
/// it was made with, and an app's model is built at run time, not compiled
/// into the bundle. So each store keeps its own: the `Model` and indexes it
/// was opened with, as JSON in the managed object model's version
/// identifiers, which Core Data writes into the store's metadata. Opening it
/// with another model migrates it with an inferred mapping when
/// `canMigrate(from:to:)` says what they share is the same, and otherwise
/// fails with `migrationRequired`, or empties it for `.reset`.
actor CoreDataStores: ModelStorageProvider {

    let directory: URL

    /// The stores open now, with the model each was opened with. Opening one
    /// again with that model shares its container.
    private var opened: [String: (model: StoredModel, container: NSPersistentContainer)] = [:]

    init(directory: String) {
        self.directory = URL(fileURLWithPath: directory, isDirectory: true)
    }

    func folder(_ name: String) -> URL {
        directory.appendingPathComponent(name, isDirectory: true)
    }

    func file(_ name: String) -> URL {
        folder(name).appendingPathComponent("Store.sqlite")
    }

    func open(_ name: String, model: Model, indexes: [EntityName: [[PropertyKey]]], migration: ModelMigration) async throws -> any ModelStorage {
        let wanted = StoredModel(model: model, indexes: indexes)
        if let open = opened[name], open.model == wanted {
            return open.container
        }
        close(name)
        let destination = try Self.managedModel(wanted)
        let file = file(name)
        if FileManager.default.fileExists(atPath: file.path) {
            let metadata: [String: Any]
            do {
                metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: file, options: nil)
            } catch {
                throw ModelStoreError(.corrupted, message: "the store \(name) can't be read: \(error.localizedDescription)")
            }
            let stored = StoredModel(metadata: metadata)
            if stored != wanted {
                try migrate(name, from: stored, to: wanted, destination, migration)
            }
        }
        do {
            try FileManager.default.createDirectory(at: folder(name), withIntermediateDirectories: true)
        } catch {
            throw Self.translate(error)
        }
        let container = NSPersistentContainer(name: name, managedObjectModel: destination)
        container.persistentStoreDescriptions = [Self.description(file)]
        var failure: (any Error)?
        container.loadPersistentStores { _, error in
            failure = error
        }
        if let failure {
            throw Self.translate(failure)
        }
        opened[name] = (wanted, container)
        return container
    }

    func destroy(_ name: String) async throws {
        close(name)
        try remove(name)
    }

    /// Brings the store `name` to `wanted`, or empties it, or refuses.
    private func migrate(_ name: String, from stored: StoredModel?, to wanted: StoredModel, _ destination: NSManagedObjectModel, _ migration: ModelMigration) throws {
        guard let stored else {
            guard migration == .reset else {
                throw ModelStoreError(.migrationRequired, message: "the store \(name) doesn't say what model it was made with")
            }
            return try remove(name)
        }
        guard InMemoryModelStorageProvider.canMigrate(from: stored.model, to: wanted.model) else {
            guard migration == .reset else {
                throw ModelStoreError(.migrationRequired, message: "the store \(name) was made with another model")
            }
            return try remove(name)
        }
        let file = file(name)
        let migrated = folder(name).appendingPathComponent("Migrating.sqlite")
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: destination)
        do {
            let source = try Self.managedModel(stored)
            let mapping = try NSMappingModel.inferredMappingModel(forSourceModel: source, destinationModel: destination)
            try Self.removeFiles(of: migrated)
            try NSMigrationManager(sourceModel: source, destinationModel: destination).migrateStore(
                from: file, sourceType: NSSQLiteStoreType, options: nil, with: mapping,
                toDestinationURL: migrated, destinationType: NSSQLiteStoreType, destinationOptions: nil
            )
        } catch {
            try? Self.removeFiles(of: migrated)
            if let error = Self.translate(error) as? ModelStoreError {
                throw error
            }
            // Core Data couldn't infer it, though the models agree on what
            // they share: as for a model that can't be migrated.
            guard migration == .reset else {
                throw ModelStoreError(.migrationRequired, message: "the store \(name) couldn't be migrated: \(error.localizedDescription)")
            }
            return try remove(name)
        }
        do {
            try coordinator.replacePersistentStore(at: file, destinationOptions: nil, withPersistentStoreFrom: migrated, sourceOptions: nil, ofType: NSSQLiteStoreType)
            try Self.removeFiles(of: migrated)
        } catch {
            throw Self.translate(error)
        }
    }

    /// Lets go of the open store `name`, before its file is migrated or
    /// removed. Its container fails from now on.
    private func close(_ name: String) {
        guard let open = opened.removeValue(forKey: name) else { return }
        let coordinator = open.container.persistentStoreCoordinator
        for store in coordinator.persistentStores {
            try? coordinator.remove(store)
        }
    }

    private func remove(_ name: String) throws {
        let folder = folder(name)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        do {
            try FileManager.default.removeItem(at: folder)
        } catch {
            throw Self.translate(error)
        }
    }

    /// Deletes a SQLite file and the journal files beside it. Core Data's
    /// `destroyPersistentStore` would leave an empty file.
    static func removeFiles(of file: URL) throws {
        for suffix in ["", "-wal", "-shm"] {
            let path = file.path + suffix
            if FileManager.default.fileExists(atPath: path) {
                try FileManager.default.removeItem(atPath: path)
            }
        }
    }

    // MARK: Core Data

    static func description(_ file: URL) -> NSPersistentStoreDescription {
        let description = NSPersistentStoreDescription(url: file)
        description.type = NSSQLiteStoreType
        description.shouldAddStoreAsynchronously = false
        // Migration is done above, with the stored model.
        description.shouldMigrateStoreAutomatically = false
        description.shouldInferMappingModelAutomatically = false
        #if os(iOS)
        description.setOption(FileProtectionType.completeUntilFirstUserAuthentication as NSObject, forKey: NSPersistentStoreFileProtectionKey)
        #endif
        return description
    }

    /// Core Data's model for `stored`, which carries `stored` itself.
    static func managedModel(_ stored: StoredModel) throws -> NSManagedObjectModel {
        let managed: NSManagedObjectModel
        do {
            managed = try NSManagedObjectModel(model: stored.model)
        } catch {
            throw ModelStoreError(.invalidModel, message: String(describing: error))
        }
        for (entity, indexes) in stored.indexes {
            guard let description = managed.entitiesByName[entity] else { continue }
            description.indexes = indexes.map { keys in
                let elements = keys.compactMap { key in
                    description.propertiesByName[key].map { NSFetchIndexElementDescription(property: $0, collationType: .binary) }
                }
                return NSFetchIndexDescription(name: ([entity] + keys).joined(separator: "_"), elements: elements)
            }
        }
        managed.versionIdentifiers = [stored.identifier]
        return managed
    }

    /// The contract's error for what Core Data, SQLite or the file system
    /// threw: a full disk and a damaged file have codes of their own.
    static func translate(_ error: any Error) -> any Error {
        if error is ModelStoreError {
            return error
        }
        var pending = [error as NSError]
        var seen = 0
        while let error = pending.popLast(), seen < 32 {
            seen += 1
            let sqlite = error.domain == NSSQLiteErrorDomain ? error.code : (error.userInfo[NSSQLiteErrorDomain] as? Int)
            switch sqlite {
            case 13: // SQLITE_FULL
                return ModelStoreError(.outOfSpace, message: error.localizedDescription)
            case 11, 26: // SQLITE_CORRUPT, SQLITE_NOTADB
                return ModelStoreError(.corrupted, message: error.localizedDescription)
            default:
                break
            }
            if error.domain == NSCocoaErrorDomain, error.code == NSFileWriteOutOfSpaceError {
                return ModelStoreError(.outOfSpace, message: error.localizedDescription)
            }
            if error.domain == NSPOSIXErrorDomain, error.code == Int(ENOSPC) {
                return ModelStoreError(.outOfSpace, message: error.localizedDescription)
            }
            if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
                pending.append(underlying)
            }
            if let detailed = error.userInfo[NSDetailedErrorsKey] as? [NSError] {
                pending.append(contentsOf: detailed)
            }
        }
        return error
    }
}

/// The model a store was opened with, in one order, so two that say the
/// same thing are equal.
struct StoredModel: Equatable, Codable {

    var model: Model

    var indexes: [String: [[String]]]

    init(model: Model, indexes: [EntityName: [[PropertyKey]]]) {
        self.model = Model(entities: model.entities
            .map { entity in
                EntityDescription(
                    id: entity.id,
                    attributes: entity.attributes.sorted { $0.id.rawValue < $1.id.rawValue },
                    relationships: entity.relationships.sorted { $0.id.rawValue < $1.id.rawValue }
                )
            }
            .sorted { $0.id.rawValue < $1.id.rawValue })
        var byName = [String: [[String]]]()
        for (entity, lists) in indexes where !lists.isEmpty {
            let keys = Set(lists.map { $0.map(\.rawValue) })
            byName[entity.rawValue] = keys.sorted { $0.lexicographicallyPrecedes($1) }
        }
        self.indexes = byName
    }

    /// The one in a store's metadata; `nil` for a store without one.
    init?(metadata: [String: Any]) {
        guard let identifiers = metadata[NSStoreModelVersionIdentifiersKey] as? [Any],
              let text = identifiers.lazy.compactMap({ $0 as? String }).first(where: { $0.hasPrefix(Self.prefix) }),
              let stored = try? JSONDecoder().decode(StoredModel.self, from: Data(text.dropFirst(Self.prefix.count).utf8))
        else {
            return nil
        }
        self = stored
    }

    static let prefix = "org.pureswift.DarwinModelStore:"

    /// What goes in the model's version identifiers.
    var identifier: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(self)) ?? Data()
        return Self.prefix + String(decoding: data, as: UTF8.self)
    }
}
