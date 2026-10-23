import Foundation
import Security

struct DistributionInfo: Equatable {
    private static let adHocFlag: UInt32 = 0x0000_0002
    private static let hardenedRuntimeFlag: UInt32 = 0x0001_0000

    let signingIdentifier: String?
    let teamIdentifier: String?
    let isAdHocSigned: Bool
    let isHardenedRuntime: Bool
    let isSandboxed: Bool
    let isInApplications: Bool

    static func snapshot(bundle: Bundle = .main) -> DistributionInfo {
        let information = signingInformation(for: bundle.bundleURL)
        let flags = (information[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0

        return DistributionInfo(
            signingIdentifier: information[kSecCodeInfoIdentifier as String] as? String,
            teamIdentifier: information[kSecCodeInfoTeamIdentifier as String] as? String,
            isAdHocSigned: flags & adHocFlag != 0,
            isHardenedRuntime: flags & hardenedRuntimeFlag != 0,
            isSandboxed: sandboxEntitlementEnabled(),
            isInApplications: bundle.bundleURL.resolvingSymlinksInPath().path.hasPrefix("/Applications/")
        )
    }

    var signatureSummary: String {
        if isAdHocSigned {
            return "ad-hoc (development only)"
        }
        guard let teamIdentifier else {
            return "signed without a team identifier"
        }
        return "signed · team \(teamIdentifier)"
    }

    var hardenedRuntimeSummary: String {
        isHardenedRuntime ? "enabled" : "disabled"
    }

    var sandboxSummary: String {
        isSandboxed ? "enabled" : "disabled"
    }

    var report: String {
        """
        Signature: \(signatureSummary)
        Signing identifier: \(signingIdentifier ?? "unknown")
        Hardened runtime: \(hardenedRuntimeSummary)
        App Sandbox: \(sandboxSummary)
        Installed in /Applications: \(isInApplications)
        """
    }

    private static func signingInformation(for url: URL) -> [String: Any] {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else {
            return [:]
        }

        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
            let dictionary = information as? [String: Any] else {
            return [:]
        }

        return dictionary
    }

    private static func sandboxEntitlementEnabled() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(
            task,
            "com.apple.security.app-sandbox" as CFString,
            nil
        )
        return (value as? Bool) == true
    }
}
