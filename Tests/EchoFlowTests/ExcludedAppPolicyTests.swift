import XCTest
@testable import EchoFlowCore

final class ExcludedAppPolicyTests: XCTestCase {
    func testMissingPersistedPolicyUsesBuiltInDefaults() {
        let policy = try! XCTUnwrap(ExcludedAppPolicy.resolvePersisted(nil))
        XCTAssertTrue(policy.isExcluded(bundleIdentifier: "com.1password.1password"))
    }

    func testMalformedOrIncompletePersistedPolicyFailsClosed() {
        XCTAssertNil(ExcludedAppPolicy.resolvePersisted(Data("not-json".utf8)))
        XCTAssertNil(ExcludedAppPolicy.resolvePersisted(Data("{}".utf8)))
    }

    func testValidPersistedPolicyKeepsUserExclusions() throws {
        var policy = ExcludedAppPolicy()
        policy.addUserExclusion(bundleIdentifier: "com.acme.vault", displayName: "Acme Vault")
        let data = try JSONEncoder().encode(policy)

        let resolved = try XCTUnwrap(ExcludedAppPolicy.resolvePersisted(data))
        XCTAssertTrue(resolved.isExcluded(bundleIdentifier: "com.acme.vault"))
    }

    func testDefaultsExcludeCommonPasswordManagers() {
        let policy = ExcludedAppPolicy()

        XCTAssertTrue(policy.isExcluded(bundleIdentifier: "com.1password.1password"))
        XCTAssertTrue(policy.isExcluded(bundleIdentifier: "com.lastpass.lastpass"))
        XCTAssertTrue(policy.isExcluded(bundleIdentifier: "com.bitwarden.desktop"))
        XCTAssertTrue(policy.isExcluded(bundleIdentifier: "com.agilebits.onepassword7"))
        XCTAssertTrue(policy.isExcluded(bundleIdentifier: "com.agilebits.onepassword"))
    }

    func testDefaultMatchingNormalizesBundleIdentifierCase() {
        let policy = ExcludedAppPolicy()

        XCTAssertTrue(policy.isExcluded(bundleIdentifier: "COM.1PASSWORD.1PASSWORD"))
    }

    func testUnrelatedApplicationIsNotExcludedByDefault() {
        let policy = ExcludedAppPolicy()

        XCTAssertFalse(policy.isExcluded(bundleIdentifier: "com.example.password-manager"))
    }

    func testMissingAndEmptyBundleIdentifiersAreNotExcluded() {
        let policy = ExcludedAppPolicy()

        XCTAssertFalse(policy.isExcluded(bundleIdentifier: nil))
        XCTAssertFalse(policy.isExcluded(bundleIdentifier: ""))
        XCTAssertFalse(policy.isExcluded(bundleIdentifier: "  \n "))
    }

    func testUserCanAddAndRemoveASelectedApplicationByBundleIdentifier() {
        var policy = ExcludedAppPolicy()
        policy.addUserExclusion(bundleIdentifier: " com.acme.vault ", displayName: "Acme Vault")

        XCTAssertTrue(policy.isExcluded(bundleIdentifier: "COM.ACME.VAULT"))
        XCTAssertEqual(
            policy.userExcludedApplications,
            [ExcludedApplication(bundleIdentifier: "com.acme.vault", displayName: "Acme Vault")]
        )

        policy.removeUserExclusion(bundleIdentifier: "COM.ACME.VAULT")

        XCTAssertFalse(policy.isExcluded(bundleIdentifier: "com.acme.vault"))
        XCTAssertTrue(policy.isExcluded(bundleIdentifier: "com.1password.1password"))
    }

    func testAddingAnEmptyBundleIdentifierDoesNothing() {
        var policy = ExcludedAppPolicy()

        policy.addUserExclusion(bundleIdentifier: " \n ", displayName: "Invalid app")

        XCTAssertTrue(policy.userExcludedApplications.isEmpty)
    }

    func testPolicyCanRoundTripThroughCodable() throws {
        var policy = ExcludedAppPolicy()
        policy.addUserExclusion(bundleIdentifier: "com.acme.vault", displayName: "Acme Vault")

        let data = try JSONEncoder().encode(policy)
        let decoded = try JSONDecoder().decode(ExcludedAppPolicy.self, from: data)

        XCTAssertEqual(decoded, policy)
        XCTAssertTrue(decoded.isExcluded(bundleIdentifier: "com.1password.1password"))
        XCTAssertTrue(decoded.isExcluded(bundleIdentifier: "com.acme.vault"))
    }
}
