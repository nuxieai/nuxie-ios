import Foundation
import XCTest

final class BazelMacOSHomeTests: XCTestCase {
  func testFoundationHomeAndApplicationSupportArePrivateAndWritable() throws {
    let environment = ProcessInfo.processInfo.environment
    let expectedHome = try XCTUnwrap(environment["NUXIE_MACOS_TEST_HOME"])
    let scratch = try XCTUnwrap(environment["NUXIE_MACOS_TEST_TMPDIR"])
    XCTAssertEqual(environment["HOME"], expectedHome)
    XCTAssertEqual(NSHomeDirectory(), expectedHome)
    let home = URL(fileURLWithPath: expectedHome).standardizedFileURL
    XCTAssertTrue(home.path.hasPrefix(URL(fileURLWithPath: scratch).standardizedFileURL.path + "/"))
    let support = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask,
      appropriateFor: nil, create: true
    ).standardizedFileURL
    XCTAssertTrue(support.path.hasPrefix(home.path + "/"))
    let probe = support.appendingPathComponent("bazel-home-oracle-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: probe) }
    let payload = Data("private writable Foundation home".utf8)
    try payload.write(to: probe)
    XCTAssertEqual(try Data(contentsOf: probe), payload)
  }
}
