import Foundation

#if canImport(UIKit)
import UIKit

public typealias NuxiePlatformViewController = UIViewController
#elseif canImport(AppKit)
import AppKit

public typealias NuxiePlatformViewController = NSViewController
#endif
