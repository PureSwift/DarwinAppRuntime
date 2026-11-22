import Contacts
import DynamicContacts
import Foundation
import RuntimeContacts

/// `HostContacts`' directory: the user's address book, through
/// `CNContactStore`.
///
/// - **Everyone** in the user's order (`sortOrder = .userDefault`), as
///   unified people, with `CNContactFormatter`'s name.
/// - **A search** is the system's own by name
///   (`predicateForContacts(matchingName:)`), and then whoever has an email
///   address that starts with the text.
/// - **A save** is a `CNSaveRequest`. A new person goes to the default
///   account. A change is made on the person as fetched, so what a
///   `Contact` doesn't carry, such as the photo and the note, is kept.
///
/// Called off the main thread, one call at a time. A contact's note needs an
/// entitlement, so it's never fetched.
final class SystemAddressBook: ContactDirectory, @unchecked Sendable {

    let store: CNContactStore

    init(store: CNContactStore = CNContactStore()) {
        self.store = store
    }

    private func request(_ predicate: NSPredicate? = nil) -> CNContactFetchRequest {
        let request = CNContactFetchRequest(keysToFetch: ContactValues.keys)
        request.predicate = predicate
        request.sortOrder = .userDefault
        request.unifyResults = true
        return request
    }

    /// The people a request finds, `limit` of them at most.
    private func fetch(_ request: CNContactFetchRequest, limit: Int? = nil, where include: (CNContact) -> Bool = { _ in true }) throws(ContactStoreError) -> [Contact] {
        var found = [Contact]()
        do {
            try store.enumerateContacts(with: request) { contact, stop in
                guard include(contact) else { return }
                found.append(ContactValues.contact(contact))
                if let limit, found.count >= limit {
                    stop.pointee = true
                }
            }
        } catch {
            throw ContactValues.error(error)
        }
        return found
    }

    /// The person as the store has them, for a change.
    private func fetched(_ identifier: String) throws(ContactStoreError) -> CNContact? {
        do {
            return try store.unifiedContact(withIdentifier: identifier, keysToFetch: ContactValues.keys)
        } catch {
            let error = ContactValues.error(error)
            if error == .notFound {
                return nil
            }
            throw error
        }
    }

    // MARK: Finding

    func contacts() throws(ContactStoreError) -> [Contact] {
        try fetch(request())
    }

    func contacts(matching text: String, limit: Int?) throws(ContactStoreError) -> [Contact] {
        let wanted = text.trimmingCharacters(in: .whitespaces)
        let byName = try fetch(request(CNContact.predicateForContacts(matchingName: wanted)), limit: limit)
        if let limit, byName.count >= limit {
            return byName
        }
        // Then an email address that starts with the text.
        let named = Set(byName.compactMap(\.id))
        let prefix = wanted.lowercased()
        let byEmail = try fetch(request(), limit: limit.map { $0 - byName.count }) { contact in
            !named.contains(contact.identifier)
                && contact.emailAddresses.contains { ($0.value as String).lowercased().hasPrefix(prefix) }
        }
        return byName + byEmail
    }

    func contact(withID identifier: String) throws(ContactStoreError) -> Contact? {
        try fetched(identifier).map(ContactValues.contact)
    }

    // MARK: Changing

    func save(_ contact: Contact) throws(ContactStoreError) -> Contact {
        let request = CNSaveRequest()
        let mutable: CNMutableContact
        if let identifier = contact.id {
            guard let existing = try fetched(identifier) else {
                throw .notFound
            }
            guard let copy = existing.mutableCopy() as? CNMutableContact else {
                throw .unknown
            }
            mutable = copy
            ContactValues.fill(mutable, from: contact)
            request.update(mutable)
        } else {
            mutable = CNMutableContact()
            ContactValues.fill(mutable, from: contact)
            request.add(mutable, toContainerWithIdentifier: nil)
        }
        do {
            try store.execute(request)
        } catch {
            throw ContactValues.error(error)
        }
        // As the store has them now, named.
        return try fetched(mutable.identifier).map(ContactValues.contact) ?? ContactValues.contact(mutable)
    }

    func remove(_ contact: Contact) throws(ContactStoreError) {
        guard let identifier = contact.id, let existing = try fetched(identifier),
              let mutable = existing.mutableCopy() as? CNMutableContact else {
            throw .notFound
        }
        let request = CNSaveRequest()
        request.delete(mutable)
        do {
            try store.execute(request)
        } catch {
            throw ContactValues.error(error)
        }
    }
}
