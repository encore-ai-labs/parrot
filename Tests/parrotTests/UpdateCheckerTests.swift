import Darwin
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

    func testRestartPreservesDaemonArgumentsAndWaitsForOldProcess() {
        XCTAssertEqual(
            UpdateInstaller.restartArguments(
                currentArguments: ["/usr/local/bin/parrot", "run", "--hotkey", "right-option"],
                waitingFor: 1234
            ),
            ["run", "--hotkey", "right-option", "--wait-for-pid", "1234"]
        )
    }

    func testReleasedUpdaterUsesImmutableVersionedInstallerWithCacheBuster() {
        let url = UpdateInstaller.installerURL(
            appVersion: "0.16.0",
            cacheToken: "test-token"
        )

        XCTAssertEqual(
            url.path,
            "/encore-ai-labs/parrot/v0.16.0/scripts/install.sh"
        )
        XCTAssertEqual(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
            [URLQueryItem(name: "parrot-cache", value: "test-token")]
        )
    }

    func testDevelopmentUpdaterUsesCacheBustedMasterInstaller() {
        let url = UpdateInstaller.installerURL(
            appVersion: "development",
            cacheToken: "development-token"
        )

        XCTAssertEqual(
            url.path,
            "/encore-ai-labs/parrot/master/scripts/install.sh"
        )
        XCTAssertEqual(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
            [URLQueryItem(name: "parrot-cache", value: "development-token")]
        )
    }

    func testUpdaterRunnerPassesArgumentsAndEnvironment() throws {
        XCTAssertNoThrow(
            try UpdateInstaller.run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "test \"$PARROT_RUNNER_TEST\" = inherited && test \"$1\" = 'argument with spaces'", "sh", "argument with spaces"],
                label: "testing updater runner",
                environment: ["PARROT_RUNNER_TEST": "inherited"]
            )
        )
    }

    func testUpdaterRunnerReportsExitStatus() {
        XCTAssertThrowsError(
            try UpdateInstaller.run(
                executable: URL(fileURLWithPath: "/usr/bin/false"),
                arguments: [],
                label: "testing failed updater command"
            )
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "testing failed updater command exited with status 1"
            )
        }
    }

    func testUpdaterRunnerInheritsProcessGroup() throws {
        let parentProcessGroup = getpgrp()
        XCTAssertGreaterThan(parentProcessGroup, 0)

        XCTAssertNoThrow(
            try UpdateInstaller.run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c",
                    "set -- $(/bin/ps -o pgid= -p $$) && test \"$1\" = \"$PARROT_EXPECTED_PGID\"",
                ],
                label: "testing updater process-group inheritance",
                environment: ["PARROT_EXPECTED_PGID": String(parentProcessGroup)]
            )
        )
    }
}
