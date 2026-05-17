import Foundation
#if canImport(UIKit)
import UIKit
#endif

private final class StaticFramework3ResourceBundleFinder {}

private let staticFramework3ResourceBundle: Bundle = {
    let bundleName = "StaticFramework3Resources"
    let finderBundle = Bundle(for: StaticFramework3ResourceBundleFinder.self)
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

public enum StaticFramework3Resources {
    public static var bundle: Bundle { staticFramework3ResourceBundle }
}

public extension Bundle {
    static var module: Bundle { StaticFramework3Resources.bundle }
}

public struct StaticFramework3ImageAsset {
    public let name: String

    public var image: UIImage {
        UIImage(named: name, in: StaticFramework3Resources.bundle, compatibleWith: nil) ?? UIImage()
    }
}

public struct StaticFramework3ColorAsset {
    public let name: String

    public var color: UIColor {
        UIColor(named: name, in: StaticFramework3Resources.bundle, compatibleWith: nil) ?? UIColor.clear
    }
}

public enum StaticFramework3Asset {
    public static let assetCatalogLogo = StaticFramework3ImageAsset(name: "assetCatalogLogo")
    public static let tuistBlue = StaticFramework3ColorAsset(name: "tuistBlue")
}
