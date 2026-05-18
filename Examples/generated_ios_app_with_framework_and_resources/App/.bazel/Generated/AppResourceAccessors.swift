import Foundation
#if canImport(UIKit)
import UIKit
#endif

private final class AppResourceBundleFinder {}

private let appResourceBundle: Bundle = {
    let bundleName = "AppResources"
    let finderBundle = Bundle(for: AppResourceBundleFinder.self)
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

public enum AppResources {
    public static var bundle: Bundle { appResourceBundle }
}

public extension Bundle {
    static var module: Bundle { AppResources.bundle }
}

public struct AppImageAsset {
    public let name: String

    public var image: UIImage {
        UIImage(named: name, in: AppResources.bundle, compatibleWith: nil) ?? UIImage()
    }
}

public struct AppColorAsset {
    public let name: String

    public var color: UIColor {
        UIColor(named: name, in: AppResources.bundle, compatibleWith: nil) ?? UIColor.clear
    }
}

public enum AppAsset {
    public static let assetCatalogLogo = AppImageAsset(name: "assetCatalogLogo")
    public static let tuistBlue = AppColorAsset(name: "tuistBlue")
}

public enum AppStrings {
public enum App {
    public static var app: String {
        NSLocalizedString("app", tableName: "App", bundle: AppResources.bundle, value: "", comment: "")
    }

    public static func appleCount(_ value: Int) -> String {
        let format = NSLocalizedString("apple_count", tableName: "App", bundle: AppResources.bundle, value: "", comment: "")
        return String.localizedStringWithFormat(format, value)
    }
}

public enum Greetings {
    public static var morning: String {
        NSLocalizedString("morning", tableName: "Greetings", bundle: AppResources.bundle, value: "", comment: "")
    }
}
}

public enum AnotherPlist {
    private static let values: [String: Any] = {
        guard let url = AppResources.bundle.url(forResource: "AnotherPlist", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let values = plist as? [String: Any] else {
            return [:]
        }
        return values
    }()

    public static var myArray: Any {
        values["my_array"] ?? ()
    }

    public static var myBoolKey: Bool {
        values["my_bool_key"] as? Bool ?? false
    }

    public static var myDictionary: Any {
        values["my_dictionary"] ?? ()
    }

    public static var myKey: String {
        values["my_key"] as? String ?? ""
    }

    public static var someNumber: Int {
        values["some_Number"] as? Int ?? 0
    }

    public static var thisIsADate: Date {
        values["this_is_a_date"] as? Date ?? Date(timeIntervalSince1970: 0)
    }
}

public enum Environment {
    private static let values: [String: Any] = {
        guard let url = AppResources.bundle.url(forResource: "Environment", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let values = plist as? [String: Any] else {
            return [:]
        }
        return values
    }()

    public static var myBoolKey: Bool {
        values["my_bool_key"] as? Bool ?? false
    }

    public static var myKey: String {
        values["my_key"] as? String ?? ""
    }
}

public struct AppFontConvertible {
    public let name: String
}

#if canImport(UIKit)
public extension UIFont {
    convenience init?(font: AppFontConvertible, size: CGFloat) {
        self.init(name: font.name, size: size)
    }
}
#endif

public enum AppFontFamily {
    public enum SFProDisplay {
        public static let bold = AppFontConvertible(name: "SF-Pro-Display-Bold")
        public static let boldItalic = AppFontConvertible(name: "SF-Pro-Display-BoldItalic")
        public static let heavy = AppFontConvertible(name: "SF-Pro-Display-Heavy")
    }
}
