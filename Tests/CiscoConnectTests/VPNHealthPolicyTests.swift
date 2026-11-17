import XCTest
@testable import CiscoConnect

final class VPNHealthPolicyTests: XCTestCase {
    func testTransientFailureDoesNotWarnAndRepeatedFailureRecovers() {
        var policy = VPNHealthPolicy()
        policy.record(reachable: false)
        XCTAssertFalse(policy.isUnavailable)
        policy.record(reachable: false)
        XCTAssertTrue(policy.isUnavailable)
        policy.record(reachable: true)
        XCTAssertFalse(policy.isUnavailable)
        policy.record(reachable: false)
        XCTAssertFalse(policy.isUnavailable)
    }
    func testNewConnectionDoesNotInheritFailures() {
        var previous = VPNHealthPolicy()
        previous.record(reachable: false)
        previous.record(reachable: false)
        XCTAssertTrue(previous.isUnavailable)
        XCTAssertFalse(VPNHealthPolicy().isUnavailable)
    }
}
