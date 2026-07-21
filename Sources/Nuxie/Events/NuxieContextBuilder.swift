import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Context builder for layered property enrichment
public class NuxieContextBuilder {
    
    // MARK: - Properties
    
    private let identityService: IdentityServiceProtocol?
    private let configuration: NuxieConfiguration?
    
    // Cache static context to avoid repeated system calls
    private let staticContextTask: Task<[String: Any], Never>
    
    // MARK: - Initialization
    
    internal init(identityService: IdentityServiceProtocol?, configuration: NuxieConfiguration?) {
        self.identityService = identityService
        self.configuration = configuration
        self.staticContextTask = Task { await Self.buildStaticDeviceContext() }
    }
    
    // MARK: - Context Building
    
    /// Build complete enriched properties using a layered approach
    /// - Parameter customProperties: User-provided properties
    /// - Returns: Fully enriched properties dictionary
    public func buildEnrichedProperties(customProperties: [String: Any] = [:]) async -> [String: Any] {
        var enriched: [String: Any] = [:]
        
        // Layer 1: Static Device Context (cached)
        let staticContext = await staticContextTask.value
        enriched.merge(staticContext) { _, new in new }
        
        // Layer 2: Dynamic Context  
        let dynamicContext = await buildDynamicContext()
        enriched.merge(dynamicContext) { _, new in new }
        
        // Layer 3: SDK Context
        enriched.merge(buildSDKContext()) { _, new in new }
        
        // Layer 4: User Context
        enriched.merge(buildUserContext()) { _, new in new }
        
        // Layer 5: Custom Properties (highest precedence)
        enriched.merge(customProperties) { _, new in new }
        
        return enriched
    }
    
    // MARK: - Layer 1: Static Device Context
    
    /// Build static device context (cached for performance)
    /// These properties don't change during app lifetime
    private static func buildStaticDeviceContext() async -> [String: Any] {
        var context: [String: Any] = [:]
        
        // App information
        if let appName = Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String {
            context["$app_name"] = appName
        } else if let appName = Bundle.main.infoDictionary?["CFBundleName"] as? String {
            context["$app_name"] = appName
        }
        
        if let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            context["$app_version"] = appVersion
        }
        
        if let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
            context["$app_build"] = buildNumber
        }
        
        if let bundleId = Bundle.main.bundleIdentifier {
            context["$app_bundle_id"] = bundleId
        }
        
        // Device information
        context["$device_manufacturer"] = "Apple"
        context["$device_model"] = getDeviceModel()
        context["$device_type"] = await getDeviceType()
        
        // Operating system
        let processInfo = ProcessInfo.processInfo
        context["$os_name"] = processInfo.operatingSystemVersionString
        context["$os_version"] = getOSVersionString()
        
        // Environment detection
        context["$is_emulator"] = isRunningInSimulator()
        context["$is_debug"] = isDebugBuild()
        
        return context
    }
    
    // MARK: - Layer 2: Dynamic Context
    
    /// Build dynamic context that can change during app lifetime
    private func buildDynamicContext() async -> [String: Any] {
        var context: [String: Any] = [:]
        
        // Screen information
        #if canImport(UIKit)
        let screenInfo = await MainActor.run { () -> (CGFloat, CGFloat, CGFloat) in
            let screen = UIScreen.main.bounds.size
            return (screen.width, screen.height, UIScreen.main.scale)
        }
        context["$screen_width"] = Float(screenInfo.0)
        context["$screen_height"] = Float(screenInfo.1)
        context["$screen_scale"] = Float(screenInfo.2)
        #elseif canImport(AppKit)
        let screenSize = await MainActor.run { NSScreen.main?.frame.size }
        if let screenSize {
            context["$screen_width"] = Float(screenSize.width)
            context["$screen_height"] = Float(screenSize.height)
        }
        #endif
        
        // Locale and timezone
        let locale = Locale.current
        context["$locale"] = locale.identifier
        context["$language"] = locale.languageCode
        context["$country"] = locale.regionCode
        
        let timezone = TimeZone.current
        context["$timezone"] = timezone.identifier
        context["$timezone_offset"] = timezone.secondsFromGMT()
        
        // Network connectivity (if available)
        context["$network_type"] = getNetworkType()
        
        // Memory information (cast UInt64 to Int to avoid encoding issues)
        context["$memory_total"] = Int(getTotalMemory())
        context["$memory_available"] = Int(getAvailableMemory())
        
        return context
    }
    
    // MARK: - Layer 3: SDK Context
    
    /// Build SDK-specific context
    private func buildSDKContext() -> [String: Any] {
        var context: [String: Any] = [:]
        
        // SDK information
        context["$lib"] = "nuxie-ios"
        context["$lib_version"] = SDKVersion.current
        
        // Configuration context
        if let config = configuration {
            context["$environment"] = config.environment.rawValue
            context["$log_level"] = config.logLevel.rawValue
        }
        
        return context
    }
    
    // MARK: - Layer 4: User Context
    
    /// Build user and identity context
    private func buildUserContext() -> [String: Any] {
        var context: [String: Any] = [:]
        
        // Identity information
        if let identityService = identityService {
            context["$distinct_id"] = identityService.getDistinctId()
            context["$is_identified"] = identityService.isIdentified
            
            if let rawDistinctId = identityService.getRawDistinctId() {
                context["$user_id"] = rawDistinctId
            }
            
            context["$anonymous_id"] = identityService.getAnonymousId()
        }
        
        return context
    }
    
    // MARK: - Utility Methods
    
    private static func getDeviceModel() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        let identifier = machineMirror.children.reduce("") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return identifier }
            return identifier + String(UnicodeScalar(UInt8(value)))
        }
        return identifier
    }
    
    private static func getDeviceType() async -> String {
        #if os(iOS)
        return await MainActor.run {
            UIDevice.current.userInterfaceIdiom == .pad ? "Tablet" : "Mobile"
        }
        #elseif os(macOS)
        return "Desktop"
        #elseif os(tvOS)
        return "TV"
        #elseif os(watchOS)
        return "Watch"
        #else
        return "Unknown"
        #endif
    }
    
    private static func getOSVersionString() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
    
    private static func isRunningInSimulator() -> Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }
    
    private static func isDebugBuild() -> Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
    
    private func getNetworkType() -> String {
        // This would require network framework integration
        // For now, return unknown
        return "unknown"
    }
    
    #if canImport(UIKit)
    #endif
    
    private func getTotalMemory() -> UInt64 {
        return ProcessInfo.processInfo.physicalMemory
    }
    
    private func getAvailableMemory() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
        
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_,
                         task_flavor_t(MACH_TASK_BASIC_INFO),
                         $0,
                         &count)
            }
        }
        
        if kerr == KERN_SUCCESS {
            return info.resident_size
        }
        
        return 0
    }
}
