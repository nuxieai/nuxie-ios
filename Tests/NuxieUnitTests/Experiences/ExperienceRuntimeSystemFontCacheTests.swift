import Foundation
import XCTest
@testable import NuxieRuntime

final class ExperienceRuntimeSystemFontCacheTests: XCTestCase {
    private struct Miss: Error {}

    func testOnlySuccessfulImportMakesAnExtractionReusable() throws {
        let cache = ExperienceRuntimeSystemFontCache()
        var extractions = 0
        let extract = { extractions += 1; return self.font("a") }
        let first = cache.candidate(for: "os/font/400", extract: extract)
        _ = cache.candidate(for: "os/font/400", extract: extract)
        XCTAssertEqual(extractions, 2, "Preparation alone must not admit bytes")
        cache.didImport([first])
        let reused = try cache.candidate(for: "os/font/400") { throw Miss() }
        XCTAssertEqual(reused.candidate.bytes, first.candidate.bytes)
        cache.didFailImport([reused])
        XCTAssertThrowsError(try cache.candidate(for: "os/font/400") { throw Miss() })
    }

    func testFailedExtractionIsNotCachedAndDifferentOSSourcesMiss() {
        let cache = ExperienceRuntimeSystemFontCache()
        XCTAssertThrowsError(try cache.candidate(for: "os1/fontA/400") { throw Miss() })
        let first = cache.candidate(for: "os1/fontA/400") { font("a") }
        cache.didImport([first])
        XCTAssertThrowsError(try cache.candidate(for: "os2/fontA/400") { throw Miss() })
        XCTAssertThrowsError(try cache.candidate(for: "os1/fontB/400") { throw Miss() })
    }

    func testFailureInvalidatesAllAliasesButNotNewerContent() throws {
        let cache = ExperienceRuntimeSystemFontCache()
        let old = cache.candidate(for: "os/font/400") { font("old") }
        let alias = cache.candidate(for: "os/font/700") { font("old") }
        cache.didImport([old, alias])
        // A concurrent extraction of new content completed after the old lease.
        let replacement = ExperienceRuntimeSystemFontCache.Lease(requestIdentity: "os/font/400", candidate: font("new"))
        cache.didImport([replacement])
        cache.didFailImport([old])
        XCTAssertThrowsError(try cache.candidate(for: "os/font/700") { throw Miss() })
        let retained = try cache.candidate(for: "os/font/400") { throw Miss() }
        XCTAssertEqual(retained.candidate.contentSHA256, "new")
    }

    func testBudgetCountsSharedContentOnceAndEvictsLeastRecentlyUsedRequests() throws {
        let cache = ExperienceRuntimeSystemFontCache(maximumBytes: 4)
        let first = cache.candidate(for: "400") { font("shared", size: 4) }
        let second = cache.candidate(for: "700") { font("shared", size: 4) }
        cache.didImport([first, second])
        XCTAssertNoThrow(try cache.candidate(for: "400") { throw Miss() })
        XCTAssertNoThrow(try cache.candidate(for: "700") { throw Miss() })
        let other = cache.candidate(for: "900") { font("different", size: 4) }
        cache.didImport([other])
        XCTAssertThrowsError(try cache.candidate(for: "400") { throw Miss() })
        XCTAssertThrowsError(try cache.candidate(for: "700") { throw Miss() })
        XCTAssertNoThrow(try cache.candidate(for: "900") { throw Miss() })
    }

    func testOversizedCandidateCanBeUsedWithoutBecomingACacheEntry() {
        let cache = ExperienceRuntimeSystemFontCache(maximumBytes: 3)
        let candidate = cache.candidate(for: "400") { font("large", size: 4) }
        XCTAssertEqual(candidate.candidate.bytes.count, 4)
        cache.didImport([candidate])
        XCTAssertThrowsError(try cache.candidate(for: "400") { throw Miss() })
    }

    private func font(_ digest: String, size: Int = 4) -> ExperienceRuntimeSystemFontProvider.Candidate {
        .init(bytes: Data(repeating: 1, count: size), sourceIdentity: "os/source/\(digest)", contentSHA256: digest, extraction: .file)
    }
}
