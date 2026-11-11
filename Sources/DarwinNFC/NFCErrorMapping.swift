import DarwinHost
import DynamicNFC
import Foundation
#if canImport(CoreNFC) && os(iOS) && !targetEnvironment(macCatalyst)
import CoreNFC
#endif

/// CoreNFC's `NFCReaderError` codes to `NFCError` codes.
///
/// It works on raw codes, so it compiles and is tested on macOS too, and
/// covers codes newer than the deployment target (`ineligible`,
/// `accessNotAccepted`, iOS 26).
enum NFCErrorMapping {

    /// `NFCErrorDomain`.
    static var domain: String {
        #if canImport(CoreNFC) && os(iOS) && !targetEnvironment(macCatalyst)
        return NFCErrorDomain
        #else
        return "NFCError"
        #endif
    }

    /// The contract code for an `NFCReaderError` code; nil when the contract
    /// has no slot for it.
    ///
    /// - Parameter inBackground: Whether the app left the foreground. iOS
    ///   ends sessions then with "terminated unexpectedly".
    static func code(_ code: Int, inBackground: Bool = false) -> NFCError? {
        switch code {
        case 1: .unsupported                    // unsupportedFeature
        case 2: .missingDeclaration             // securityViolation: entitlement, usage string, AID
        case 3, 4, 5: .invalidParameter         // invalidParameter, …Length, parameterOutOfBound
        case 6: .disabled                       // radioDisabled
        case 7: .unsupported                    // ineligible
        case 100: .tagConnectionLost            // tagConnectionLost
        case 101, 102: .transceiveFailed        // retryExceeded, tagResponseError
        case 103: .tagNotConnected              // sessionInvalidated
        case 104: .tagNotConnected              // tagNotConnected
        case 105: .invalidParameter             // packetTooLong
        case 200: .userCancelled                // userCanceled
        case 201: .sessionTimeout               // sessionTimeout
        case 202: inBackground ? .appInBackground : nil  // sessionTerminatedUnexpectedly
        case 203: .systemBusy                   // systemIsBusy
        case 300: .invalidParameter             // tagCommandConfiguration invalidParameters
        case 400: .tagReadOnly                  // tagNotWritable
        case 402: .capacityExceeded             // tagSizeTooSmall
        case 403: .invalidParameter             // zeroLengthMessage
        default: nil
        }
    }

    /// The `Int32` a delegate method takes for `error`: `0` for nil, the
    /// mapped code, or `unknown`, logged with the original error.
    static func code(for error: (any Error)?, operation: String, inBackground: Bool = false) -> Int32 {
        guard let error else {
            return 0
        }
        let nsError = error as NSError
        if nsError.domain == domain, let mapped = code(nsError.code, inBackground: inBackground) {
            return mapped.rawValue
        }
        AppHost.logger.error("""
            NFC \(operation, privacy: .public) failed with an error the contract has no code for \
            (\(nsError.domain, privacy: .public) \(nsError.code, privacy: .public)): \
            \(nsError.localizedDescription, privacy: .public)
            """)
        return NFCError.unknown.rawValue
    }
}
