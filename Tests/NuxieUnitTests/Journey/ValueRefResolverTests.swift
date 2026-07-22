import Foundation
import Quick
import Nimble
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

final class ValueRefResolverTests: QuickSpec {
    override class func spec() {
        func makeResolver(
            payload: [String: Any]? = nil,
            values: [String: Any] = [:]
        ) -> ValueRefResolver {
            ValueRefResolver(
                payload: payload,
                lookup: { path in values[path.path] }
            )
        }

        describe("resolve") {
            it("passes plain values through") {
                let resolver = makeResolver()
                expect(resolver.resolve("hello") as? String) == "hello"
                expect(resolver.resolve(42) as? Int) == 42
            }

            it("unwraps single-key literal dictionaries") {
                let resolver = makeResolver()
                expect(resolver.resolve(["literal": "abc"]) as? String) == "abc"
                // A [String: AnyCodable] dictionary bridges to [String: Any]
                // first, so the literal comes back still wrapped — pinned
                // behavior carried over from the runner.
                let wrapped = resolver.resolve(["literal": AnyCodable(7)] as [String: AnyCodable])
                expect((wrapped as? AnyCodable)?.value as? Int) == 7
            }

            it("resolves path refs through the lookup") {
                let resolver = makeResolver(values: ["price/monthly": 9.99])
                let ref: [String: Any] = ["ref": ["kind": "path", "path": "price/monthly"]]
                expect(resolver.resolve(ref) as? Double) == 9.99
            }

            it("resolves payload refs against the trigger payload") {
                let resolver = makeResolver(payload: ["product": ["id": "pro_monthly"]])
                let ref: [String: Any] = ["ref": ["kind": "payload", "path": "product.id"]]
                expect(resolver.resolve(ref) as? String) == "pro_monthly"
            }

            it("recurses into arrays and multi-key dictionaries") {
                let resolver = makeResolver(values: ["a": 1])
                let value: [String: Any] = [
                    "first": ["literal": "x"],
                    "second": [["ref": ["kind": "path", "path": "a"]]],
                ]
                let resolved = resolver.resolve(value) as? [String: Any]
                expect(resolved?["first"] as? String) == "x"
                expect((resolved?["second"] as? [Any])?.first as? Int) == 1
            }

            it("leaves single-key dicts that are neither literal nor ref untouched") {
                let resolver = makeResolver()
                let value: [String: Any] = ["other": "y"]
                expect((resolver.resolve(value) as? [String: Any])?["other"] as? String) == "y"
            }
        }

        describe("parseRefPath") {
            it("parses path refs with view model metadata") {
                let ref = ValueRefResolver.parseRefPath([
                    "kind": "path",
                    "path": "a/b",
                    "viewModelName": "vm",
                    "isRelative": true,
                ] as [String: Any])
                expect(ref?.path) == "a/b"
                expect(ref?.viewModelName) == "vm"
            }

            it("rejects payload-kind and malformed values") {
                expect(ValueRefResolver.parseRefPath(["kind": "payload", "path": "a"] as [String: Any])).to(beNil())
                expect(ValueRefResolver.parseRefPath("nope")).to(beNil())
            }
        }

        describe("parsePayloadRefPath") {
            it("parses payload refs and rejects empty paths") {
                expect(ValueRefResolver.parsePayloadRefPath(["kind": "payload", "path": "a.b"] as [String: Any])) == "a.b"
                expect(ValueRefResolver.parsePayloadRefPath(["kind": "payload", "path": ""] as [String: Any])).to(beNil())
                expect(ValueRefResolver.parsePayloadRefPath(["kind": "path", "path": "a"] as [String: Any])).to(beNil())
            }
        }

        describe("resolvePayloadPath") {
            it("walks dotted paths through nested dictionaries") {
                let payload: [String: Any] = ["a": ["b": ["c": 3]]]
                expect(ValueRefResolver.resolvePayloadPath("a.b.c", in: payload) as? Int) == 3
            }

            it("walks AnyCodable dictionaries") {
                // Same bridging note as above: the nested dictionary is
                // walked via the [String: Any] cast, so the leaf keeps its
                // AnyCodable wrapper — pinned behavior from the runner.
                let payload: [String: Any] = ["a": ["b": AnyCodable("z")] as [String: AnyCodable]]
                let leaf = ValueRefResolver.resolvePayloadPath("a.b", in: payload)
                expect((leaf as? AnyCodable)?.value as? String) == "z"
            }

            it("returns nil for missing segments or nil payloads") {
                expect(ValueRefResolver.resolvePayloadPath("a.x", in: ["a": ["b": 1]])).to(beNil())
                expect(ValueRefResolver.resolvePayloadPath("a", in: nil)).to(beNil())
            }
        }

        describe("EventPayloadSchemaMatcher") {
            it("matches when every declared field has the declared type") {
                let schema: EventPayloadSchema = [
                    "name": .string,
                    "count": .number,
                    "flag": .boolean,
                    "meta": .object,
                    "items": .array,
                ]
                let payload: [String: Any] = [
                    "name": "a",
                    "count": 2,
                    "flag": true,
                    "meta": ["k": "v"],
                    "items": [1, 2],
                ]
                expect(EventPayloadSchemaMatcher.matches(payload, schema: schema)) == true
            }

            it("fails on missing or mistyped fields") {
                let schema: EventPayloadSchema = ["name": .string]
                expect(EventPayloadSchemaMatcher.matches([:], schema: schema)) == false
                expect(EventPayloadSchemaMatcher.matches(["name": 4], schema: schema)) == false
            }

            it("unwraps AnyCodable before type checking") {
                let schema: EventPayloadSchema = ["name": .string]
                expect(EventPayloadSchemaMatcher.matches(["name": AnyCodable("x")], schema: schema)) == true
            }
        }
    }
}
