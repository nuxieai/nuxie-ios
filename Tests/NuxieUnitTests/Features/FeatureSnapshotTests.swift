import Combine
import XCTest
@testable import Nuxie

@MainActor
final class FeatureSnapshotTests: XCTestCase {
    func testEmptyAdmissionAndClearPublishCoherentReadiness() {
        let info = FeatureInfo()
        var snapshots: [FeatureInfo.Snapshot] = []
        let subscription = info.$snapshot.sink { snapshots.append($0) }
        info.admitProfileSnapshot([:], admittedAt: Date())
        XCTAssertEqual(snapshots.last?.state, .ready)
        XCTAssertTrue(snapshots.last?.all.isEmpty == true)
        info.clear()
        XCTAssertEqual(snapshots.last?.state, .unknown)
        XCTAssertTrue(snapshots.last?.all.isEmpty == true)
        XCTAssertTrue(zip(snapshots, snapshots.dropFirst()).allSatisfy { $0.revision < $1.revision })
        withExtendedLifetime(subscription) {}
    }

    func testFractionalAccessAndReentrantClearCannotRestoreOldSnapshot() {
        let info = FeatureInfo()
        var cleared = false
        let subscription = info.$snapshot.sink { snapshot in
            if snapshot.state == .ready && !cleared {
                XCTAssertEqual(snapshot.all["credits"]?.balance, 1.5)
                cleared = true
                info.clear()
            }
        }
        info.admitProfileSnapshot(["credits": .withBalance(1.5, unlimited: false, type: .creditSystem)], admittedAt: Date())
        XCTAssertEqual(info.snapshot.state, .unknown)
        XCTAssertTrue(info.snapshot.all.isEmpty)
        withExtendedLifetime(subscription) {}
    }
}
