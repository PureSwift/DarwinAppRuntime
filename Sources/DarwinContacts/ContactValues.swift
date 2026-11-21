import Contacts
import DynamicContacts
import DynamicRuntime
import Foundation

/// Between the Contacts framework's values and the guest's.
enum ContactValues {

    // MARK: Access

    static func access(_ status: CNAuthorizationStatus) -> ContactStoreAccess {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorized: return .authorized
        default:
            // `.limited`, iOS 18's: the contacts the user chose.
            #if os(iOS)
            if #available(iOS 18, *), status == .limited {
                return .limited
            }
            #endif
            return .denied
        }
    }

    static func permission(_ access: ContactStoreAccess) -> PermissionStatus {
        switch access {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorized: return .granted
        case .limited: return .limited
        case .unavailable: return .unavailable
        }
    }

    /// The manifest's `.contacts(.readOnly, …)`:
    /// `RTCapabilityOptions.contacts.access`. Writing is the default.
    static func allowsWriting(_ info: [String: Any]) -> Bool {
        let options = info["RTCapabilityOptions"] as? [String: Any]
        let access = (options?["contacts"] as? [String: Any])?["access"] as? String
        return access != "readOnly"
    }

    // MARK: Errors

    /// What the guest is told of a failure.
    static func error(_ error: any Error) -> ContactStoreError {
        let error = error as NSError
        guard error.domain == CNErrorDomain else { return .unknown }
        switch CNError.Code(rawValue: error.code) {
        case .authorizationDenied, .unauthorizedKeys, .featureDisabledByUser:
            return .notAuthorized
        case .recordDoesNotExist, .recordIdentifierInvalid:
            return .notFound
        case .recordNotWritable, .parentContainerNotWritable, .noAccessableWritableContainers, .policyViolation:
            return .readOnly
        case .validationMultipleErrors, .validationTypeMismatch, .validationConfigurationError:
            return .invalidContact
        default:
            return .unknown
        }
    }

    // MARK: Labels

    /// The eight labels the contract names, and the platform's constant
    /// for each.
    static let labels: [(ContactLabel, String)] = [
        (.home, CNLabelHome),
        (.work, CNLabelWork),
        (.other, CNLabelOther),
        (.mobile, CNLabelPhoneNumberMobile),
        (.main, CNLabelPhoneNumberMain),
        (.homeFax, CNLabelPhoneNumberHomeFax),
        (.workFax, CNLabelPhoneNumberWorkFax),
        (.pager, CNLabelPhoneNumberPager),
    ]

    /// A platform label as the guest has it: one of the eight, the
    /// system's word for another of its constants (`iPhone`, `school`), or
    /// the user's own text.
    static func label(_ platform: String?) -> ContactLabel {
        guard let platform, !platform.isEmpty else { return .other }
        if let (label, _) = labels.first(where: { $0.1 == platform }) {
            return label
        }
        // The system's own, such as `_$!<iPhone>!$_`.
        if platform.hasPrefix("_$!<"), platform.hasSuffix(">!$_") {
            return ContactLabel(CNLabeledValue<NSString>.localizedString(forLabel: platform))
        }
        return ContactLabel(platform)
    }

    /// A guest's label as the platform keeps it: the constant for one of
    /// the eight, and the text for any other.
    static func platformLabel(_ label: ContactLabel) -> String {
        labels.first(where: { $0.0 == label })?.1 ?? label.rawValue
    }

    // MARK: Contacts

    /// What a contact is fetched with: everything a `Contact` carries, and
    /// what the formatter needs.
    static let keys: [any CNKeyDescriptor] = [
        CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
        CNContactIdentifierKey as NSString,
        CNContactTypeKey as NSString,
        CNContactNamePrefixKey as NSString,
        CNContactGivenNameKey as NSString,
        CNContactMiddleNameKey as NSString,
        CNContactFamilyNameKey as NSString,
        CNContactNameSuffixKey as NSString,
        CNContactNicknameKey as NSString,
        CNContactOrganizationNameKey as NSString,
        CNContactDepartmentNameKey as NSString,
        CNContactJobTitleKey as NSString,
        CNContactPhoneNumbersKey as NSString,
        CNContactEmailAddressesKey as NSString,
        CNContactUrlAddressesKey as NSString,
        CNContactPostalAddressesKey as NSString,
        CNContactBirthdayKey as NSString,
    ]

    /// The system's formatting of the name; without one, the
    /// organization, an email address or a phone number.
    static func displayName(_ contact: CNContact) -> String {
        if let name = CNContactFormatter.string(from: contact, style: .fullName), !name.isEmpty {
            return name
        }
        if !contact.organizationName.isEmpty { return contact.organizationName }
        if let email = contact.emailAddresses.first { return email.value as String }
        if let phone = contact.phoneNumbers.first { return phone.value.stringValue }
        return ""
    }

    static func contact(_ contact: CNContact) -> Contact {
        var value = Contact()
        value.id = contact.identifier
        value.namePrefix = contact.namePrefix
        value.givenName = contact.givenName
        value.middleName = contact.middleName
        value.familyName = contact.familyName
        value.nameSuffix = contact.nameSuffix
        value.nickname = contact.nickname
        value.organizationName = contact.organizationName
        value.departmentName = contact.departmentName
        value.jobTitle = contact.jobTitle
        value.phoneNumbers = contact.phoneNumbers.map { LabeledValue(label($0.label), $0.value.stringValue) }
        value.emailAddresses = contact.emailAddresses.map { LabeledValue(label($0.label), $0.value as String) }
        value.urls = contact.urlAddresses.map { LabeledValue(label($0.label), $0.value as String) }
        value.postalAddresses = contact.postalAddresses.map { LabeledValue(label($0.label), address($0.value)) }
        value.birthday = contact.birthday.flatMap(date)
        return value.named(displayName(contact))
    }

    /// Writes what a `Contact` carries into `mutable`, keeping the rest.
    /// The lists replace the ones there were; a value that's there already,
    /// with the same label, is kept as it is, with its identifier and the
    /// platform's own label.
    static func fill(_ mutable: CNMutableContact, from contact: Contact) {
        mutable.namePrefix = contact.namePrefix
        mutable.givenName = contact.givenName
        mutable.middleName = contact.middleName
        mutable.familyName = contact.familyName
        mutable.nameSuffix = contact.nameSuffix
        mutable.nickname = contact.nickname
        mutable.organizationName = contact.organizationName
        mutable.departmentName = contact.departmentName
        mutable.jobTitle = contact.jobTitle
        mutable.phoneNumbers = merge(contact.phoneNumbers, into: mutable.phoneNumbers, read: { $0.stringValue }) {
            CNPhoneNumber(stringValue: $0)
        }
        mutable.emailAddresses = merge(contact.emailAddresses, into: mutable.emailAddresses, read: { $0 as String }) {
            $0 as NSString
        }
        mutable.urlAddresses = merge(contact.urls, into: mutable.urlAddresses, read: { $0 as String }) {
            $0 as NSString
        }
        mutable.postalAddresses = merge(contact.postalAddresses, into: mutable.postalAddresses, read: address) {
            postalAddress($0)
        }
        mutable.birthday = contact.birthday.map(components)
    }

    /// The guest's list, reusing what's there of it.
    private static func merge<Value: Hashable, Platform: NSCopying & NSSecureCoding>(
        _ values: [LabeledValue<Value>],
        into existing: [CNLabeledValue<Platform>],
        read: (Platform) -> Value,
        make: (Value) -> Platform
    ) -> [CNLabeledValue<Platform>] {
        var unused = existing
        return values.map { value in
            if let index = unused.firstIndex(where: { label($0.label) == value.label && read($0.value) == value.value }) {
                return unused.remove(at: index)
            }
            return CNLabeledValue(label: platformLabel(value.label), value: make(value.value))
        }
    }

    // MARK: Addresses and dates

    static func address(_ address: CNPostalAddress) -> PostalAddress {
        PostalAddress(
            street: address.street, city: address.city, region: address.state,
            postalCode: address.postalCode, country: address.country, isoCountryCode: address.isoCountryCode
        )
    }

    static func postalAddress(_ address: PostalAddress) -> CNPostalAddress {
        let postal = CNMutablePostalAddress()
        postal.street = address.street
        postal.city = address.city
        postal.state = address.region
        postal.postalCode = address.postalCode
        postal.country = address.country
        postal.isoCountryCode = address.isoCountryCode
        return postal
    }

    /// A birthday's month and day, and its year if it's known. One in
    /// another calendar than the Gregorian is `nonGregorianBirthday`, and
    /// isn't read.
    static func date(_ components: DateComponents) -> ContactDate? {
        guard let month = components.month, let day = components.day,
              month != NSDateComponentUndefined, day != NSDateComponentUndefined else {
            return nil
        }
        let year = components.year.flatMap { $0 == NSDateComponentUndefined ? nil : $0 }
        return ContactDate(year: year, month: month, day: day)
    }

    static func components(_ date: ContactDate) -> DateComponents {
        DateComponents(year: date.year, month: date.month, day: date.day)
    }
}
