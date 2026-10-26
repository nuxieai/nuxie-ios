import Foundation
import XCTest
@testable import Nuxie

/// The shared in-page Back table, replayed over the page history, rows and
/// stack the way the coordinator and page controller drive them.
final class ExperiencePageBackVectorTests: XCTestCase {

    func testPageBackVectors() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/sdk/page-back.json")
        let vectors = try JSONDecoder().decode(PageBackVectors.self, from: Data(contentsOf: url))
        XCTAssertFalse(vectors.cases.isEmpty)
        let declarations = vectors.declarations.map(\.native)
        for vector in vectors.cases {
            var pages = [Page(root: vector.first)]
            for (index, operation) in vector.operations.enumerated() {
                let label = "\(vector.name), operation \(index + 1)"
                var outcome = Outcome(page: pages.count - 1)
                if let screen = operation.push {
                    pages.append(Page(root: screen))
                    outcome.page = pages.count - 1
                } else if let target = operation.forward {
                    let top = pages.count - 1
                    outcome.target = target
                    if pages[top].active == target {
                        outcome.stays = true
                    } else {
                        let raw = operation.transition.map { ["type": $0.kind, "transitionId": $0.id] }
                        let spec = ExperienceScreenTransitionSpec.pageTransition(raw: raw,
                            sourceScreenID: pages[top].active, isBack: false, diagnostic: { _ in })
                        let played = Self.played(spec, from: pages[top].active, to: target, declarations: declarations)
                        var next = pages[top].history
                        next.visit(target, transition: played)
                        outcome.removed = pages[top].step(to: target, isBack: false, next: next)
                        outcome.plays = played
                    }
                } else if let steps = operation.back {
                    let histories = pages.map(\.history.screenIDs)
                    let location = try XCTUnwrap(ExperiencePageStack.back(steps: steps, histories: histories), label)
                    let top = pages.count - 1
                    outcome.target = location.screenID
                    outcome.page = location.page
                    if location.page == top {
                        let source = pages[top].active
                        if source == location.screenID {
                            outcome.stays = true
                            outcome.removed = pages[top].trim(to: location.screenID, steps: steps)
                        } else {
                            let spec = pages[top].history.backTransition(steps: steps, target: location.screenID,
                                declarations: declarations)
                            let played = Self.played(spec, from: source, to: location.screenID, declarations: declarations)
                            var next = pages[top].history
                            next.back(to: location.screenID, steps: steps)
                            outcome.removed = pages[top].step(to: location.screenID, isBack: true, next: next)
                            outcome.plays = played
                        }
                    } else {
                        // The lower page cuts, covered, to the target unless it already shows it (P7).
                        let cutSteps = pages[location.page].history.screenIDs.count - 1 - location.entry
                        let cuts = pages[location.page].active != location.screenID || cutSteps != 0
                        if cuts {
                            var next = pages[location.page].history
                            next.back(to: location.screenID, steps: cutSteps)
                            outcome.removed = pages[location.page].step(to: location.screenID, isBack: true, next: next)
                        }
                        outcome.across = .init(page: location.page, cutsLowerPage: cuts, pops: top - location.page)
                        pages.removeLast(top - location.page)
                    }
                }
                guard let expect = operation.expect else { continue }
                outcome.check(expect, pages: pages, label: label)
            }
        }
    }

    /// Mirrors the page controller: a named transition plays only when the release
    /// declares it for this pair of Screens, in either direction; anything else is a cut.
    private static func played(_ spec: ExperienceScreenTransitionSpec, from source: String, to target: String,
                               declarations: [NativeExperienceTransition]) -> ExperienceScreenTransitionSpec {
        let plan = spec.transitionId.flatMap {
            ExperienceScreenCustomTransitionPlan.resolve(transitionId: $0, sourceScreenId: source,
                destinationScreenId: target, declarations: declarations)
        }
        return plan.map { _ in ExperienceScreenTransitionSpec(kind: spec.kind, transitionId: spec.transitionId) } ?? .none
    }
}

private struct Page {
    var history: ExperiencePageHistory
    var rows = ExperiencePageRows()

    init(root: String) {
        history = .init(root: root)
        _ = rows.take(root)
    }

    var active: String { history.screenIDs.last ?? "" }

    /// The page step's row changes: place the incoming row (position), wake it
    /// (expand), then retire what the history after the step no longer reaches.
    mutating func step(to target: String, isBack: Bool, next: ExperiencePageHistory) -> [String] {
        let source = active
        if !rows.screenIDs.contains(target) {
            _ = rows.take(target)
            if isBack { _ = rows.position(target, relativeTo: source, isBack: true) }
        } else {
            _ = rows.position(target, relativeTo: source, isBack: isBack)
        }
        _ = rows.take(target)
        history = next
        return retire(active: target)
    }

    /// A Back to the Screen already showing trims the history and retires only.
    mutating func trim(to target: String, steps: Int) -> [String] {
        history.back(to: target, steps: steps)
        return retire(active: target)
    }

    private mutating func retire(active: String) -> [String] {
        rows.retire(active: active, reachable: Set(history.screenIDs)).compactMap { mutation -> String? in
            guard case .remove(let id, _) = mutation else { return nil }
            return id
        }
    }
}

private struct Outcome {
    struct Across: Equatable {
        let page: Int
        let cutsLowerPage: Bool
        let pops: Int
    }
    var page: Int
    var target: String?
    var plays: ExperienceScreenTransitionSpec?
    var stays = false
    var across: Across?
    var removed: [String] = []

    func check(_ expect: PageBackVectors.Expect, pages: [Page], label: String) {
        XCTAssertEqual(pages.map(\.history.screenIDs), expect.history, "history: \(label)")
        if let target = expect.target { XCTAssertEqual(self.target, target, "target: \(label)") }
        XCTAssertEqual(stays, expect.stays ?? false, "stays: \(label)")
        if expect.playsIsGiven {
            XCTAssertNil(across, "an in-page step: \(label)")
            XCTAssertEqual(plays, expect.plays?.spec ?? ExperienceScreenTransitionSpec.none, "plays: \(label)")
        }
        XCTAssertEqual(across, expect.acrossPages.map { Across(page: $0.page, cutsLowerPage: $0.cutsLowerPage, pops: $0.pops) },
            "acrossPages: \(label)")
        guard pages.indices.contains(page) else { return XCTFail("landing page \(page): \(label)") }
        if let rows = expect.rows { XCTAssertEqual(pages[page].rows.screenIDs, rows, "rows: \(label)") }
        if let collapsed = expect.collapsed { XCTAssertEqual(pages[page].rows.collapsed, Set(collapsed), "collapsed: \(label)") }
        if let removed = expect.removed { XCTAssertEqual(Set(self.removed), Set(removed), "removed: \(label)") }
    }
}

private struct PageBackVectors: Decodable {
    struct Declaration: Decodable {
        let id: String
        let from: String
        let to: String
        let defaultPair: Bool

        var native: NativeExperienceTransition {
            .init(id: id, kind: .page, isDefaultPair: defaultPair, sourceScreenId: from, destinationScreenId: to,
                durationMs: 450, incomingOnTop: true, source: .init(completeEventName: "nx_exit_done:\(id)"),
                destination: .init(completeEventName: "nx_enter_done:\(id)"),
                reverse: .init(durationMs: 450, incomingOnTop: nil, source: .init(completeEventName: "nx_exit_done:\(id).reverse"),
                    destination: .init(completeEventName: "nx_enter_done:\(id).reverse")))
        }
    }
    struct Transition: Decodable {
        let kind: String
        let id: String

        var spec: ExperienceScreenTransitionSpec {
            .init(kind: kind == "fade" ? .fade : .magicMove, transitionId: id)
        }
    }
    struct AcrossPages: Decodable {
        let page: Int
        let cutsLowerPage: Bool
        let pops: Int
    }
    struct Expect: Decodable {
        let target: String?
        let plays: Transition?
        /// `plays: null` is a cut; a missing `plays` is not checked.
        let playsIsGiven: Bool
        let stays: Bool?
        let acrossPages: AcrossPages?
        let history: [[String]]
        let rows: [String]?
        let collapsed: [String]?
        let removed: [String]?

        private enum CodingKeys: String, CodingKey {
            case target, plays, stays, acrossPages, history, rows, collapsed, removed
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            target = try container.decodeIfPresent(String.self, forKey: .target)
            plays = try container.decodeIfPresent(Transition.self, forKey: .plays)
            playsIsGiven = container.contains(.plays)
            stays = try container.decodeIfPresent(Bool.self, forKey: .stays)
            acrossPages = try container.decodeIfPresent(AcrossPages.self, forKey: .acrossPages)
            history = try container.decode([[String]].self, forKey: .history)
            rows = try container.decodeIfPresent([String].self, forKey: .rows)
            collapsed = try container.decodeIfPresent([String].self, forKey: .collapsed)
            removed = try container.decodeIfPresent([String].self, forKey: .removed)
        }
    }
    struct Operation: Decodable {
        let forward: String?
        let transition: Transition?
        let push: String?
        let back: Int?
        let expect: Expect?
    }
    struct Case: Decodable {
        let name: String
        let first: String
        let operations: [Operation]
    }
    let declarations: [Declaration]
    let cases: [Case]
}
