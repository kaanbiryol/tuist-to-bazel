import Foundation
#if canImport(UIKit)
import UIKit
#endif

private final class StaticFramework4ResourceBundleFinder {}

private let staticFramework4ResourceBundle: Bundle = {
    let bundleName = "StaticFramework4Resources"
    let finderBundle = Bundle(for: StaticFramework4ResourceBundleFinder.self)
    let candidates = [
        Bundle.main.resourceURL,
        Bundle.main.bundleURL,
        finderBundle.resourceURL,
        finderBundle.bundleURL,
    ]

    for candidate in candidates {
        if let bundleURL = candidate?.appendingPathComponent(bundleName + ".bundle"),
           let bundle = Bundle(url: bundleURL) {
            return bundle
        }
    }

    return finderBundle
}()

public enum StaticFramework4Resources {
    public static var bundle: Bundle { staticFramework4ResourceBundle }
}

public extension Bundle {
    static var module: Bundle { StaticFramework4Resources.bundle }
}
