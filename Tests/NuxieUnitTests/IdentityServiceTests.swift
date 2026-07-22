import Foundation
import Nimble
import Quick

@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

private struct IdentityServiceDiskModel: Codable {
  let distinctId: String?
  let anonymousId: String?
  let userPropertiesById: [String: [String: AnyCodable]]
}

final class IdentityServiceTests: AsyncSpec {
  override class func spec() {
    describe("IdentityService") {
      var identityService: IdentityService!
      var testStoragePath: URL!

      beforeEach {
        // Create unique test storage path for each test
        let tempDir = FileManager.default.temporaryDirectory
        testStoragePath = tempDir.appendingPathComponent("test-identity-\(UUID.v7().uuidString)")
        identityService = IdentityService(customStoragePath: testStoragePath)
      }

      afterEach {
        // Clean up test directory
        try? FileManager.default.removeItem(at: testStoragePath)
        identityService = nil
        testStoragePath = nil
      }

      describe("anonymous ID management") {
        it("should generate anonymous ID on first access") {
          let anonymousId = identityService.getAnonymousId()

          expect(anonymousId).toNot(beEmpty())
          // Anonymous ID is a UUIDv7, should be 36 characters with hyphens
          expect(anonymousId.count).to(equal(36))
          expect(identityService.isIdentified).to(beFalse())
        }

        it("should persist anonymous ID across instances") {
          let firstAnonymousId = identityService.getAnonymousId()

          // Create new instance (simulating app restart) with same storage path
          let newIdentityService = IdentityService(customStoragePath: testStoragePath)
          let secondAnonymousId = newIdentityService.getAnonymousId()

          expect(secondAnonymousId).to(equal(firstAnonymousId))
        }

        it("should use anonymous ID as distinct ID when not identified") {
          // Reset to ensure clean state
          identityService.reset(keepAnonymousId: true)

          let anonymousId = identityService.getAnonymousId()
          let distinctId = identityService.getDistinctId()

          expect(distinctId).to(equal(anonymousId))
          expect(identityService.getRawDistinctId()).to(beNil())
        }
      }

      describe("distinct ID management") {
        it("should set and retrieve distinct ID") {
          let testDistinctId = "user123"

          identityService.setDistinctId(testDistinctId)

          expect(identityService.getDistinctId()).to(equal(testDistinctId))
          expect(identityService.getRawDistinctId()).to(equal(testDistinctId))
          expect(identityService.isIdentified).to(beTrue())
        }

        it("should use distinct ID as distinct ID when identified") {
          let testDistinctId = "user123"
          let anonymousId = identityService.getAnonymousId()

          identityService.setDistinctId(testDistinctId)

          let effectiveId = identityService.getDistinctId()
          expect(effectiveId).to(equal(testDistinctId))
          expect(effectiveId).toNot(equal(anonymousId))
        }

        it("should persist distinct ID across instances") {
          let testDistinctId = "user123"
          identityService.setDistinctId(testDistinctId)

          // Wait a moment for async persistence to complete
          try? await Task.sleep(nanoseconds: 100_000_000)

          // Create new instance (simulating app restart) with same storage path
          let newIdentityService = IdentityService(customStoragePath: testStoragePath)

          expect(newIdentityService.getDistinctId()).to(equal(testDistinctId))
          expect(newIdentityService.getRawDistinctId()).to(equal(testDistinctId))
          expect(newIdentityService.isIdentified).to(beTrue())
        }
      }

      describe("reset functionality") {
        beforeEach {
          // Set up identified user
          _ = identityService.getAnonymousId()  // Generate anonymous ID
          identityService.setDistinctId("user123")
        }

        it("should reset distinct ID while keeping anonymous ID by default") {
          let originalAnonymousId = identityService.getAnonymousId()

          identityService.reset()

          expect(identityService.getRawDistinctId()).to(beNil())
          expect(identityService.isIdentified).to(beFalse())
          expect(identityService.getAnonymousId()).to(equal(originalAnonymousId))
          expect(identityService.getDistinctId()).to(equal(originalAnonymousId))
        }

        it("should reset distinct ID and keep anonymous ID when specified") {
          let originalAnonymousId = identityService.getAnonymousId()

          identityService.reset(keepAnonymousId: true)

          expect(identityService.getRawDistinctId()).to(beNil())
          expect(identityService.isIdentified).to(beFalse())
          expect(identityService.getAnonymousId()).to(equal(originalAnonymousId))
        }

        it("should reset both distinct ID and anonymous ID when specified") {
          let originalAnonymousId = identityService.getAnonymousId()

          identityService.reset(keepAnonymousId: false)

          expect(identityService.getRawDistinctId()).to(beNil())
          expect(identityService.isIdentified).to(beFalse())

          let newAnonymousId = identityService.getAnonymousId()
          expect(newAnonymousId).toNot(equal(originalAnonymousId))
          // New anonymous ID should also be a UUIDv7
          expect(newAnonymousId.count).to(equal(36))
        }
      }

      describe("state transitions") {
        it("should transition from anonymous to identified correctly") {
          // Start anonymous
          let anonymousId = identityService.getAnonymousId()
          expect(identityService.isIdentified).to(beFalse())
          expect(identityService.getDistinctId()).to(equal(anonymousId))

          // Identify user
          let distinctId = "user123"
          identityService.setDistinctId(distinctId)
          expect(identityService.isIdentified).to(beTrue())
          expect(identityService.getDistinctId()).to(equal(distinctId))
          expect(identityService.getAnonymousId()).to(equal(anonymousId))  // Anonymous ID preserved
        }

        it("should transition from identified back to anonymous correctly") {
          // Start with identified user
          let anonymousId = identityService.getAnonymousId()
          identityService.setDistinctId("user123")
          expect(identityService.isIdentified).to(beTrue())

          // Reset to anonymous
          identityService.reset(keepAnonymousId: true)
          expect(identityService.isIdentified).to(beFalse())
          expect(identityService.getDistinctId()).to(equal(anonymousId))
        }
      }

      describe("user properties") {
        describe("getUserProperties") {
          it("should return empty dictionary initially") {
            let properties = identityService.getUserProperties()
            expect(properties).to(beEmpty())
          }

          it("should return properties after setting them") {
            identityService.setUserProperties(["name": "John", "age": 30])

            let properties = identityService.getUserProperties()
            expect(properties["name"] as? String).to(equal("John"))
            expect(properties["age"] as? Int).to(equal(30))
          }
        }

        describe("setUserProperties") {
          it("should overwrite existing properties") {
            identityService.setUserProperties(["name": "John", "age": 30])
            identityService.setUserProperties(["name": "Jane", "city": "NYC"])

            let properties = identityService.getUserProperties()
            expect(properties["name"] as? String).to(equal("Jane"))
            expect(properties["age"] as? Int).to(equal(30))
            expect(properties["city"] as? String).to(equal("NYC"))
          }

          it("should handle various data types") {
            let testDate = Date()
            identityService.setUserProperties([
              "string": "test",
              "int": 42,
              "double": 3.14,
              "bool": true,
              "date": testDate,
              "array": [1, 2, 3],
              "dict": ["key": "value"],
            ])

            let properties = identityService.getUserProperties()
            expect(properties["string"] as? String).to(equal("test"))
            expect(properties["int"] as? Int).to(equal(42))
            expect(properties["double"] as? Double).to(beCloseTo(3.14))
            expect(properties["bool"] as? Bool).to(beTrue())
            expect(properties["date"] as? Date).to(equal(testDate))
            expect(properties["array"] as? [Int]).to(equal([1, 2, 3]))
            expect((properties["dict"] as? [String: String])?["key"]).to(equal("value"))
          }
        }

        describe("setOnceUserProperties") {
          it("should set properties only if they don't exist") {
            identityService.setUserProperties(["name": "John", "age": 30])
            identityService.setOnceUserProperties([
              "name": "Jane",  // Should not overwrite
              "age": 25,  // Should not overwrite
              "city": "NYC",  // Should be set
            ])

            let properties = identityService.getUserProperties()
            expect(properties["name"] as? String).to(equal("John"))
            expect(properties["age"] as? Int).to(equal(30))
            expect(properties["city"] as? String).to(equal("NYC"))
          }

          it("should set all properties when none exist") {
            identityService.setOnceUserProperties([
              "name": "Jane",
              "age": 25,
              "city": "NYC",
            ])

            let properties = identityService.getUserProperties()
            expect(properties["name"] as? String).to(equal("Jane"))
            expect(properties["age"] as? Int).to(equal(25))
            expect(properties["city"] as? String).to(equal("NYC"))
          }
        }

        describe("properties with reset") {
          it("should clear all user properties on reset") {
            identityService.setUserProperties(["name": "John", "age": 30])
            identityService.reset(keepAnonymousId: true)

            let properties = identityService.getUserProperties()
            expect(properties).to(beEmpty())
          }

          it("should clear properties even when keeping anonymous ID") {
            identityService.setUserProperties(["name": "John", "age": 30])
            identityService.reset(keepAnonymousId: true)

            let properties = identityService.getUserProperties()
            expect(properties).to(beEmpty())

            // Anonymous ID should still exist
            let anonymousId = identityService.getAnonymousId()
            expect(anonymousId).toNot(beEmpty())
          }

          it("should clear properties when not keeping anonymous ID") {
            identityService.setUserProperties(["name": "John", "age": 30])
            let oldAnonymousId = identityService.getAnonymousId()

            identityService.reset(keepAnonymousId: false)

            let properties = identityService.getUserProperties()
            expect(properties).to(beEmpty())

            // Anonymous ID should be different
            let newAnonymousId = identityService.getAnonymousId()
            expect(newAnonymousId).toNot(equal(oldAnonymousId))
          }
        }

        describe("properties persistence") {
          it("should persist properties across instances") {
            let userId = identityService.getDistinctId()
            let identityFileURL = testStoragePath
              .appendingPathComponent("nuxie", isDirectory: true)
              .appendingPathComponent("identity.json")

            // Set properties
            identityService.setUserProperties(["name": "John", "age": 30])

            // Wait for async persistence (disk write) to complete.
            await expect {
              guard let data = try? Data(contentsOf: identityFileURL) else { return nil }
              let model = try? JSONDecoder().decode(IdentityServiceDiskModel.self, from: data)
              return model?.userPropertiesById[userId]?["name"]?.value as? String
            }.toEventually(equal("John"), timeout: .seconds(2))

            await expect {
              guard let data = try? Data(contentsOf: identityFileURL) else { return nil }
              let model = try? JSONDecoder().decode(IdentityServiceDiskModel.self, from: data)
              return model?.userPropertiesById[userId]?["age"]?.value as? Int
            }.toEventually(equal(30), timeout: .seconds(2))

            // Create new instance with same storage path and check properties are loaded
            let newIdentityService = IdentityService(customStoragePath: testStoragePath)
            let properties = newIdentityService.getUserProperties()

            expect(properties["name"] as? String).to(equal("John"))
            expect(properties["age"] as? Int).to(equal(30))
          }

          it("should handle property updates across instances") {
            let userId = identityService.getDistinctId()
            let identityFileURL = testStoragePath
              .appendingPathComponent("nuxie", isDirectory: true)
              .appendingPathComponent("identity.json")

            // Set initial properties
            identityService.setUserProperties(["name": "John"])

            // Wait for async persistence (disk write) to complete.
            await expect {
              guard let data = try? Data(contentsOf: identityFileURL) else { return nil }
              let model = try? JSONDecoder().decode(IdentityServiceDiskModel.self, from: data)
              return model?.userPropertiesById[userId]?["name"]?.value as? String
            }.toEventually(equal("John"), timeout: .seconds(2))

            // Update in new instance
            let instance2 = IdentityService(customStoragePath: testStoragePath)
            instance2.setUserProperties(["age": 30])

            // Wait for async persistence (disk write) to complete.
            await expect {
              guard let data = try? Data(contentsOf: identityFileURL) else { return nil }
              let model = try? JSONDecoder().decode(IdentityServiceDiskModel.self, from: data)
              return model?.userPropertiesById[userId]?["age"]?.value as? Int
            }.toEventually(equal(30), timeout: .seconds(2))

            // Check in third instance
            let instance3 = IdentityService(customStoragePath: testStoragePath)
            let properties = instance3.getUserProperties()

            expect(properties["name"] as? String).to(equal("John"))
            expect(properties["age"] as? Int).to(equal(30))
          }
        }

        describe("identify with properties") {
          it("should maintain properties when identifying user") {
            identityService.setUserProperties(["name": "John", "age": 30])
            identityService.setDistinctId("user-123")

            let properties = identityService.getUserProperties()
            expect(properties["name"] as? String).to(equal("John"))
            expect(properties["age"] as? Int).to(equal(30))

            let distinctId = identityService.getDistinctId()
            expect(distinctId).to(equal("user-123"))
          }
        }
      }

      it("migrates properties from anonymous to identified on setDistinctId") {
        let anonId = identityService.getAnonymousId()
        identityService.setUserProperties(["lang": "en"])
        identityService.setDistinctId("user-123")

        // new id has the properties
        expect(identityService.getDistinctId()).to(equal("user-123"))
        expect(identityService.getUserProperties()["lang"] as? String).to(equal("en"))

        // anonymous bag is gone
        // (this checks internal behavior via the public API: switch back to anon and props should be empty)
        identityService.reset(keepAnonymousId: true)
        expect(identityService.getDistinctId()).to(equal(anonId))
        expect(identityService.getUserProperties()).to(beEmpty())
      }

      it("clears property bag on reset even when keeping anonymous id") {
        let anonId = identityService.getAnonymousId()
        identityService.setUserProperties(["foo": 1])
        identityService.reset(keepAnonymousId: true)

        expect(identityService.getAnonymousId()).to(equal(anonId))
        expect(identityService.getUserProperties()).to(beEmpty())
      }

    }
  }
}
