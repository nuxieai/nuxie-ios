import Nimble
import Quick
@testable import Nuxie

final class ResponseProjectionPathsTests: QuickSpec {
    override class func spec() {
        it("addresses the canonical response view model") {
            expect(ResponseProjectionPaths.state)
                == VmPathRef(viewModelName: "vm", path: "response/state")
            expect(ResponseProjectionPaths.value(field: "email"))
                == VmPathRef(viewModelName: "vm", path: "response/values/email")
        }
    }
}
