import XCTest
@testable import CodexGlanceCore

final class ReleaseUpdateCheckerTests: XCTestCase {
    func testVersionsCompareNumericallyAndNormalizeMissingComponents() throws {
        XCTAssertGreaterThan(try XCTUnwrap(ReleaseVersion("v0.1.10")), try XCTUnwrap(ReleaseVersion("0.1.9")))
        XCTAssertGreaterThan(try XCTUnwrap(ReleaseVersion("1.0.0")), try XCTUnwrap(ReleaseVersion("0.99.99")))
        XCTAssertEqual(ReleaseVersion("1.2"), ReleaseVersion("1.2.0"))
        XCTAssertEqual(ReleaseVersion(" v1\n"), ReleaseVersion("1.0.0"))
    }

    func testUnknownVersionFormatsAreNotSilentlyCompared() {
        for value in ["", "development", "1..2", "1.2.3.4", "-1.2.3", "1.2.3-beta.1", "1.2.3+dev", "v", "1.２.3", String(repeating: "9", count: 100)] {
            XCTAssertNil(ReleaseVersion(value), value)
        }
    }

    func testValidReleaseDetectsUpdateOrNoNewerRelease() throws {
        let data = releaseData(tag: "v0.1.10")
        XCTAssertEqual(try evaluate(data, installed: "0.1.9"), .updateAvailable(version: "v0.1.10"))
        XCTAssertEqual(try evaluate(data, installed: "0.1.10"), .noNewerRelease(version: "v0.1.10"))
        XCTAssertEqual(try evaluate(data, installed: "0.2.0"), .noNewerRelease(version: "v0.1.10"))
    }

    func testUnpackagedBuildDoesNotClaimToBeCurrent() throws {
        for installed in [nil, "development", "0.2.0-beta.1"] as [String?] {
            XCTAssertEqual(
                try evaluate(releaseData(tag: "v0.1.10"), installed: installed),
                .unknownInstalledVersion(latestVersion: "v0.1.10")
            )
        }
    }

    func testRejectsMalformedAndNonStableReleases() {
        for data in [
            Data("{}".utf8), Data("not JSON".utf8),
            releaseData(tag: "v0.1.10", draft: true),
            releaseData(tag: "v0.1.10", prerelease: true),
            releaseData(tag: "latest")
        ] {
            XCTAssertThrowsError(try evaluate(data, installed: "0.1.9")) { error in
                guard case ReleaseUpdateError.invalidRelease = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }
    }

    func testHTTPErrorsNeverBecomeSuccessfulChecks() {
        for statusCode in [403, 404, 429, 500] {
            XCTAssertThrowsError(try ReleaseUpdateChecker.evaluate(
                data: releaseData(tag: "v0.1.10"), statusCode: statusCode, installedVersion: "0.1.10"
            )) { error in
                guard case ReleaseUpdateError.httpStatus(let actual) = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
                XCTAssertEqual(actual, statusCode)
            }
        }
    }

    func testReleaseLinksAlwaysUseOfficialDestinations() throws {
        let data = Data(#"{"tag_name":"v0.1.10","draft":false,"prerelease":false,"html_url":"https://example.com/untrusted"}"#.utf8)
        XCTAssertEqual(try evaluate(data, installed: "0.1.9"), .updateAvailable(version: "v0.1.10"))
        XCTAssertEqual(ReleaseUpdateChecker.releasesURL.absoluteString, "https://github.com/Leoccino/CodexGlance/releases/latest")
        XCTAssertEqual(ReleaseUpdateChecker.websiteURL.absoluteString, "https://leoccino.github.io/CodexGlance/")
    }

    private func evaluate(_ data: Data, installed: String?) throws -> ReleaseUpdateStatus {
        try ReleaseUpdateChecker.evaluate(data: data, statusCode: 200, installedVersion: installed)
    }

    private func releaseData(tag: String, draft: Bool = false, prerelease: Bool = false) -> Data {
        Data("{\"tag_name\":\"\(tag)\",\"draft\":\(draft),\"prerelease\":\(prerelease)}".utf8)
    }
}
