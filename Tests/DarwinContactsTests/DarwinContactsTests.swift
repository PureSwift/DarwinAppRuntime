import Contacts
import DynamicContacts
import DynamicRuntime
import Foundation
import Testing
@testable import DarwinContacts

/// Between the Contacts framework's values and the guest's. Nothing here
/// touches the user's address book: the contacts are made in memory.
@Suite("Contact values")
struct ContactValueTests {

    @Test func saysWhatWasGranted() {
        #expect(ContactValues.access(.notDetermined) == .notDetermined)
        #expect(ContactValues.access(.restricted) == .restricted)
        #expect(ContactValues.access(.denied) == .denied)
        #expect(ContactValues.access(.authorized) == .authorized)
        #expect(ContactValues.permission(.authorized) == .granted)
        #expect(ContactValues.permission(.limited) == .limited)
        #expect(ContactValues.permission(.unavailable) == .unavailable)
    }

    @Test func readsWhetherTheAppWrites() {
        #expect(ContactValues.allowsWriting([:]))
        #expect(ContactValues.allowsWriting(["RTCapabilityOptions": ["contacts": ["access": "readWrite"]]]))
        #expect(!ContactValues.allowsWriting(["RTCapabilityOptions": ["contacts": ["access": "readOnly"]]]))
    }

    @Test func saysWhyItFailed() {
        func error(_ code: CNError.Code) -> ContactStoreError {
            ContactValues.error(NSError(domain: CNErrorDomain, code: code.rawValue))
        }
        #expect(error(.authorizationDenied) == .notAuthorized)
        #expect(error(.recordDoesNotExist) == .notFound)
        #expect(error(.recordNotWritable) == .readOnly)
        #expect(error(.parentContainerNotWritable) == .readOnly)
        #expect(error(.validationMultipleErrors) == .invalidContact)
        #expect(error(.communicationError) == .unknown)
        #expect(ContactValues.error(CocoaError(.fileNoSuchFile)) == .unknown)
    }

    @Test func keepsTheLabelsTheContractNames() {
        for (label, platform) in ContactValues.labels {
            #expect(ContactValues.label(platform) == label)
            #expect(ContactValues.platformLabel(label) == platform)
        }
        #expect(ContactValues.label(CNLabelPhoneNumberMobile) == .mobile)
        // The system's others are its words for them; the user's are text.
        #expect(ContactValues.label(CNLabelPhoneNumberiPhone).rawValue == CNLabeledValue<NSString>.localizedString(forLabel: CNLabelPhoneNumberiPhone))
        #expect(ContactValues.label("Lab") == ContactLabel("Lab"))
        #expect(ContactValues.platformLabel(ContactLabel("Lab")) == "Lab")
        #expect(ContactValues.label(nil) == .other)
    }

    func ada() -> CNMutableContact {
        let ada = CNMutableContact()
        ada.givenName = "Ada"
        ada.familyName = "Lovelace"
        ada.nickname = "Enchantress"
        ada.organizationName = "Analytical Engines"
        ada.jobTitle = "Programmer"
        ada.phoneNumbers = [
            CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: "+353 1 555 0100")),
            CNLabeledValue(label: CNLabelPhoneNumberiPhone, value: CNPhoneNumber(stringValue: "555-0101")),
        ]
        ada.emailAddresses = [CNLabeledValue(label: CNLabelWork, value: "ada@example.com" as NSString)]
        ada.urlAddresses = [CNLabeledValue(label: "Lab", value: "https://example.com" as NSString)]
        let address = CNMutablePostalAddress()
        address.street = "12 St James's Square"
        address.city = "London"
        address.postalCode = "SW1Y 4JH"
        address.country = "United Kingdom"
        address.isoCountryCode = "gb"
        ada.postalAddresses = [CNLabeledValue(label: CNLabelHome, value: address)]
        ada.birthday = DateComponents(year: 1815, month: 12, day: 10)
        return ada
    }

    @Test func readsAPerson() {
        let contact = ContactValues.contact(ada())
        #expect(contact.id != nil)
        #expect(contact.displayName.contains("Ada") && contact.displayName.contains("Lovelace"))
        #expect(contact.givenName == "Ada")
        #expect(contact.familyName == "Lovelace")
        #expect(contact.nickname == "Enchantress")
        #expect(contact.organizationName == "Analytical Engines")
        #expect(contact.jobTitle == "Programmer")
        #expect(contact.phoneNumbers.first == LabeledValue(.mobile, "+353 1 555 0100"))
        #expect(contact.phoneNumbers.count == 2)
        #expect(contact.emailAddresses == [LabeledValue(.work, "ada@example.com")])
        #expect(contact.urls == [LabeledValue(ContactLabel("Lab"), "https://example.com")])
        #expect(contact.postalAddresses.first?.label == .home)
        #expect(contact.postalAddresses.first?.value.city == "London")
        #expect(contact.postalAddresses.first?.value.isoCountryCode == "gb")
        #expect(contact.birthday == ContactDate(year: 1815, month: 12, day: 10))
    }

    @Test func namesSomeoneWithoutAName() {
        let company = CNMutableContact()
        company.organizationName = "Analytical Engines"
        #expect(ContactValues.contact(company).displayName == "Analytical Engines")
        let address = CNMutableContact()
        address.emailAddresses = [CNLabeledValue(label: CNLabelWork, value: "ada@example.com" as NSString)]
        #expect(ContactValues.contact(address).displayName == "ada@example.com")
        let number = CNMutableContact()
        number.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMain, value: CNPhoneNumber(stringValue: "555-0100"))]
        #expect(ContactValues.contact(number).displayName == "555-0100")
        #expect(ContactValues.contact(CNMutableContact()).displayName == "")
    }

    @Test func writesWhatTheGuestSetAndKeepsTheRest() throws {
        let stored = ada()
        stored.note = "Kept"
        let kept = try #require(stored.phoneNumbers.last)
        var contact = ContactValues.contact(stored)
        contact.familyName = "King"
        contact.phoneNumbers.removeFirst()
        contact.phoneNumbers.append(LabeledValue(.pager, "555-0102"))
        contact.emailAddresses = []
        contact.birthday = ContactDate(month: 12, day: 10)
        ContactValues.fill(stored, from: contact)
        #expect(stored.familyName == "King")
        #expect(stored.givenName == "Ada")
        // Not something a `Contact` carries.
        #expect(stored.note == "Kept")
        // The list is the guest's, and the value that was there is the
        // same one, with the system's label.
        #expect(stored.phoneNumbers.map(\.value.stringValue) == ["555-0101", "555-0102"])
        #expect(stored.phoneNumbers.first?.identifier == kept.identifier)
        #expect(stored.phoneNumbers.first?.label == CNLabelPhoneNumberiPhone)
        #expect(stored.phoneNumbers.last?.label == CNLabelPhoneNumberPager)
        #expect(stored.emailAddresses.isEmpty)
        #expect(stored.urlAddresses.first?.label == "Lab")
        #expect(stored.postalAddresses.first?.value.street == "12 St James's Square")
        #expect(stored.birthday?.year == nil)
        #expect(stored.birthday?.month == 12)
        #expect(ContactValues.contact(stored).birthday == ContactDate(month: 12, day: 10))
    }

    @Test func makesANewPerson() {
        var contact = Contact()
        contact.givenName = "Grace"
        contact.phoneNumbers = [LabeledValue(.home, "555-0199")]
        contact.postalAddresses = [LabeledValue(.work, PostalAddress(city: "Arlington", region: "VA"))]
        let mutable = CNMutableContact()
        ContactValues.fill(mutable, from: contact)
        #expect(mutable.givenName == "Grace")
        #expect(mutable.phoneNumbers.first?.label == CNLabelHome)
        #expect(mutable.phoneNumbers.first?.value.stringValue == "555-0199")
        #expect(mutable.postalAddresses.first?.label == CNLabelWork)
        #expect(mutable.postalAddresses.first?.value.state == "VA")
        #expect(mutable.birthday == nil)
    }
}
