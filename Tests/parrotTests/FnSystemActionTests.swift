import XCTest
@testable import parrot

final class FnSystemActionTests: XCTestCase {
    func testDisablesAndRestoresExistingAction() throws {
        let store = MemoryFnPreferences(2)
        let override = try FnSystemActionOverride(store: store)

        XCTAssertEqual(override.state, .disabledForParrot)
        XCTAssertEqual(store.value, 0)

        try override.restore()
        XCTAssertEqual(store.value, 2)
    }

    func testLeavesAnAlreadyDisabledActionAlone() throws {
        let store = MemoryFnPreferences(0)
        let override = try FnSystemActionOverride(store: store)

        XCTAssertEqual(override.state, .alreadyDisabled)
        XCTAssertEqual(store.writes, [])
        try override.restore()
        XCTAssertEqual(store.writes, [])
    }

    func testRestoreIsIdempotent() throws {
        let store = MemoryFnPreferences(3)
        let override = try FnSystemActionOverride(store: store)

        try override.restore()
        try override.restore()
        XCTAssertEqual(store.writes, [0, 3])
    }
}

private final class MemoryFnPreferences: FnSystemActionPreferenceStoring {
    var value: Int
    var writes: [Int] = []

    init(_ value: Int) {
        self.value = value
    }

    func read() throws -> Int { value }

    func write(_ value: Int) throws {
        writes.append(value)
        self.value = value
    }
}
