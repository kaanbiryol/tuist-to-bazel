import Foundation
#if canImport(UIKit)
import UIKit
#endif

private final class StaticFramework5ResourceBundleFinder {}

private let staticFramework5ResourceBundle: Bundle = {
    let bundleName = "StaticFramework5Resources"
    let finderBundle = Bundle(for: StaticFramework5ResourceBundleFinder.self)
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

public enum StaticFramework5Resources {
    public static var bundle: Bundle { staticFramework5ResourceBundle }
}

public extension Bundle {
    static var module: Bundle { StaticFramework5Resources.bundle }
}

public struct StaticFramework5ImageAsset {
    public let name: String

    public var image: UIImage {
        UIImage(named: name, in: StaticFramework5Resources.bundle, compatibleWith: nil) ?? UIImage()
    }
}

public struct StaticFramework5ColorAsset {
    public let name: String

    public var color: UIColor {
        UIColor(named: name, in: StaticFramework5Resources.bundle, compatibleWith: nil) ?? UIColor.clear
    }
}

public enum StaticFramework5Asset {
    public static let sprite = StaticFramework5ImageAsset(name: "Sprite")
    public static let sprites = StaticFramework5ImageAsset(name: "Sprites")
    public static let staticFramework5ResourcesTuist = StaticFramework5ImageAsset(name: "StaticFramework5Resources-tuist")
    public static let symbol = StaticFramework5ImageAsset(name: "Symbol")
    public static let color = StaticFramework5ColorAsset(name: "Color")
}

public enum StaticFramework5Strings {
public enum Localizable {
    public static var testString: String {
        NSLocalizedString("Test String", tableName: "Localizable", bundle: StaticFramework5Resources.bundle, value: "", comment: "")
    }
}
}

public enum PropertyList {
    private static let values: [String: Any] = {
        guard let url = StaticFramework5Resources.bundle.url(forResource: "Property List", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let values = plist as? [String: Any] else {
            return [:]
        }
        return values
    }()

    public static var key: String {
        values["Key"] as? String ?? ""
    }
}
