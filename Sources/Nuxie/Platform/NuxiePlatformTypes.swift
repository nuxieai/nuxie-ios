import Foundation

#if canImport(UIKit)
import UIKit

typealias NuxiePlatformViewController = UIViewController
#elseif canImport(AppKit)
import AppKit

typealias NuxiePlatformViewController = NSViewController
#endif
