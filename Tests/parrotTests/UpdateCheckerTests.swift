import XCTest

@testable import parrot

final class UpdateCheckerTests: XCTestCase {
    func testDevelopmentBuildReportsWhyItDidNotCheck() {
        var result: UpdateCheckResult?
        UpdateChecker.check { result = $0 }
        XCTAssertEqual(result, .developmentBuild)
    }

    func testDetectsNewerVersions() {
        XCTAssertTrue(UpdateChecker.isNewer("v0.4.0", than: "0.3.0"))
        XCTAssertTrue(UpdateChecker.isNewer("1.0.0", than: "v0.99.99"))
        XCTAssertTrue(UpdateChecker.isNewer("v0.3.1", than: "0.3"))
    }

    func testDoesNotOfferCurrentOrOlderVersions() {
        XCTAssertFalse(UpdateChecker.isNewer("v0.3.0", than: "0.3.0"))
        XCTAssertFalse(UpdateChecker.isNewer("v0.2.9", than: "0.3.0"))
        XCTAssertFalse(UpdateChecker.isNewer("0.3", than: "0.3.0"))
    }

    func testRejectsNonVersionStrings() {
        XCTAssertFalse(UpdateChecker.isNewer("latest", than: "0.3.0"))
        XCTAssertFalse(UpdateChecker.isNewer("v0.4.0", than: "development"))
    }
}
