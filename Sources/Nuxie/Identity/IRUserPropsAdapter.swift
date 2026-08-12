import Foundation

/// Adapter that bridges IdentityServiceProtocol to IRUserProps
struct IRUserPropsAdapter: IRUserProps {
    private let identityService: IdentityServiceProtocol
    
    public init(identityService: IdentityServiceProtocol) {
        self.identityService = identityService
    }
    
    public func userProperty(for key: String) async -> Any? {
        return await identityService.userProperty(for: key)
    }
}
