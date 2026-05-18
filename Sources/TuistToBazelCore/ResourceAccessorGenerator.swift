import Foundation

struct ResourceAccessorGenerator {
    private let fileManager = FileManager.default

    func relativePath(for target: TuistTarget) -> String {
        ".bazel/Generated/\(sanitizedModuleName(target.name))ResourceAccessors.swift"
    }

    func shouldGenerate(for target: TuistTarget) -> Bool {
        guard target.product.isSwiftBacked, !target.resources.isEmpty else { return false }
        if !target.sources.contains(where: { $0.hasSuffix(".swift") }) {
            return true
        }

        let topLevelNames = Set(topLevelAccessorNames(for: target))
        guard !topLevelNames.isEmpty else { return false }

        return target.sources.contains { source in
            guard source.hasSuffix(".swift"),
                  let content = try? String(contentsOfFile: source, encoding: .utf8) else {
                return false
            }
            return topLevelNames.contains { content.contains($0) }
        }
    }

    func render(for target: TuistTarget) -> String {
        let moduleName = swiftTypeIdentifier(target.productName, fallback: target.name)
        let bundleEnumName = "\(moduleName)Resources"
        let bundleVariableName = "\(swiftPropertyIdentifier(target.productName, fallback: target.name))ResourceBundle"
        let bundleFinderName = "\(moduleName)ResourceBundleFinder"
        let resources = resourceInventory(for: target)

        var blocks = [
            """
            import Foundation
            #if canImport(UIKit)
            import UIKit
            #endif
            """,
            renderBundleAccessor(
                bundleEnumName: bundleEnumName,
                bundleVariableName: bundleVariableName,
                bundleFinderName: bundleFinderName
            ),
        ]

        if !resources.assets.isEmpty {
            blocks.append(renderAssets(resources.assets, moduleName: moduleName, bundleEnumName: bundleEnumName))
        }
        if !resources.stringTables.isEmpty || !resources.stringDictTables.isEmpty {
            blocks.append(renderStrings(
                stringTables: resources.stringTables,
                stringDictTables: resources.stringDictTables,
                moduleName: moduleName,
                bundleEnumName: bundleEnumName
            ))
        }
        if !resources.plists.isEmpty {
            blocks.append(renderPlists(resources.plists, bundleEnumName: bundleEnumName))
        }
        if !resources.fonts.isEmpty {
            blocks.append(renderFonts(resources.fonts, moduleName: moduleName))
        }

        return blocks.joined(separator: "\n\n") + "\n"
    }

    private func topLevelAccessorNames(for target: TuistTarget) -> [String] {
        let moduleName = swiftTypeIdentifier(target.productName, fallback: target.name)
        let resources = resourceInventory(for: target)
        var names = ["\(moduleName)Resources", "Bundle.module"]
        if !resources.assets.isEmpty {
            names.append("\(moduleName)Asset")
        }
        if !resources.stringTables.isEmpty || !resources.stringDictTables.isEmpty {
            names.append("\(moduleName)Strings")
        }
        if !resources.fonts.isEmpty {
            names.append("\(moduleName)FontFamily")
        }
        names.append(contentsOf: resources.plists.map(\.typeName))
        return names
    }

    private func renderBundleAccessor(
        bundleEnumName: String,
        bundleVariableName: String,
        bundleFinderName: String
    ) -> String {
        """
        private final class \(bundleFinderName) {}

        private let \(bundleVariableName): Bundle = {
            let bundleName = "\(bundleEnumName)"
            let finderBundle = Bundle(for: \(bundleFinderName).self)
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

        public enum \(bundleEnumName) {
            public static var bundle: Bundle { \(bundleVariableName) }
        }

        public extension Bundle {
            static var module: Bundle { \(bundleEnumName).bundle }
        }
        """
    }

    private func renderAssets(_ assets: [Asset], moduleName: String, bundleEnumName: String) -> String {
        var imageProperties: [String] = []
        var colorProperties: [String] = []
        for asset in assets.sorted(by: { $0.name < $1.name }) {
            let propertyName = swiftPropertyIdentifier(asset.name, fallback: asset.name)
            switch asset.kind {
            case .image:
                imageProperties.append("    public static let \(propertyName) = \(moduleName)ImageAsset(name: \"\(asset.name)\")")
            case .color:
                colorProperties.append("    public static let \(propertyName) = \(moduleName)ColorAsset(name: \"\(asset.name)\")")
            }
        }

        var blocks = [
            """
            public struct \(moduleName)ImageAsset {
                public let name: String

                public var image: UIImage {
                    UIImage(named: name, in: \(bundleEnumName).bundle, compatibleWith: nil) ?? UIImage()
                }
            }

            public struct \(moduleName)ColorAsset {
                public let name: String

                public var color: UIColor {
                    UIColor(named: name, in: \(bundleEnumName).bundle, compatibleWith: nil) ?? UIColor.clear
                }
            }
            """,
        ]

        let properties = (imageProperties + colorProperties).joined(separator: "\n")
        blocks.append(
            """
            public enum \(moduleName)Asset {
            \(properties)
            }
            """
        )
        return blocks.joined(separator: "\n\n")
    }

    private func renderStrings(
        stringTables: [StringTable],
        stringDictTables: [StringDictTable],
        moduleName: String,
        bundleEnumName: String
    ) -> String {
        let stringKeysByTable = Dictionary(grouping: stringTables, by: \.name).mapValues { tables in
            Set(tables.flatMap(\.keys))
        }
        let stringDictKeysByTable = Dictionary(grouping: stringDictTables, by: \.name).mapValues { tables in
            Set(tables.flatMap(\.keys))
        }
        let tableNames = Set(stringKeysByTable.keys).union(stringDictKeysByTable.keys)
        var tableBlocks: [String] = []

        for tableName in tableNames.sorted() {
            let typeName = swiftTypeIdentifier(tableName, fallback: tableName)
            var members: [String] = []
            members.append(contentsOf: (stringKeysByTable[tableName] ?? []).sorted().map { key in
                let propertyName = swiftPropertyIdentifier(key, fallback: key)
                return """
                    public static var \(propertyName): String {
                        NSLocalizedString("\(escapedSwiftString(key))", tableName: "\(escapedSwiftString(tableName))", bundle: \(bundleEnumName).bundle, value: "", comment: "")
                    }
                """
            })
            members.append(contentsOf: (stringDictKeysByTable[tableName] ?? []).sorted().map { key in
                let functionName = swiftPropertyIdentifier(key, fallback: key)
                return """
                    public static func \(functionName)(_ value: Int) -> String {
                        let format = NSLocalizedString("\(escapedSwiftString(key))", tableName: "\(escapedSwiftString(tableName))", bundle: \(bundleEnumName).bundle, value: "", comment: "")
                        return String.localizedStringWithFormat(format, value)
                    }
                """
            })
            tableBlocks.append(
                """
                public enum \(typeName) {
                \(members.joined(separator: "\n\n"))
                }
                """
            )
        }

        return """
        public enum \(moduleName)Strings {
        \(tableBlocks.joined(separator: "\n\n"))
        }
        """
    }

    private func renderPlists(_ plists: [PlistAccessor], bundleEnumName: String) -> String {
        plists.sorted(by: { $0.typeName < $1.typeName }).map { plist in
            let values = plist.keys.sorted { $0.propertyName < $1.propertyName }.map { key in
                let fallback = key.fallbackLiteral
                let valueExpression = key.swiftType == "Any"
                    ? "values[\"\(escapedSwiftString(key.rawName))\"] ?? \(fallback)"
                    : "values[\"\(escapedSwiftString(key.rawName))\"] as? \(key.swiftType) ?? \(fallback)"
                return """
                    public static var \(key.propertyName): \(key.swiftType) {
                        \(valueExpression)
                    }
                """
            }.joined(separator: "\n\n")

            return """
            public enum \(plist.typeName) {
                private static let values: [String: Any] = {
                    guard let url = \(bundleEnumName).bundle.url(forResource: "\(escapedSwiftString(plist.resourceName))", withExtension: "plist"),
                          let data = try? Data(contentsOf: url),
                          let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                          let values = plist as? [String: Any] else {
                        return [:]
                    }
                    return values
                }()

            \(values)
            }
            """
        }.joined(separator: "\n\n")
    }

    private func renderFonts(_ fonts: [FontAccessor], moduleName: String) -> String {
        let families = Dictionary(grouping: fonts) { $0.familyName }
        let familyBlocks = families.keys.sorted().map { familyName in
            let members = (families[familyName] ?? []).sorted(by: { $0.styleName < $1.styleName }).map { font in
                "        public static let \(font.styleName) = \(moduleName)FontConvertible(name: \"\(escapedSwiftString(font.postscriptName))\")"
            }.joined(separator: "\n")
            return """
                public enum \(familyName) {
            \(members)
                }
            """
        }.joined(separator: "\n\n")

        return """
        public struct \(moduleName)FontConvertible {
            public let name: String
        }

        #if canImport(UIKit)
        public extension UIFont {
            convenience init?(font: \(moduleName)FontConvertible, size: CGFloat) {
                self.init(name: font.name, size: size)
            }
        }
        #endif

        public enum \(moduleName)FontFamily {
        \(familyBlocks)
        }
        """
    }

    private func resourceInventory(for target: TuistTarget) -> ResourceInventory {
        let files = resourceFiles(for: target)
        let assetCatalogs = assetCatalogDirectories(for: target)
        return ResourceInventory(
            assets: assetCatalogs.flatMap(assetAccessors(in:)),
            stringTables: stringTables(in: files),
            stringDictTables: stringDictTables(in: files),
            plists: plistAccessors(in: files),
            fonts: fontAccessors(in: files)
        )
    }

    private func resourceFiles(for target: TuistTarget) -> [String] {
        var result: Set<String> = []
        for resource in target.resources {
            if isDirectory(resource.path) {
                if let enumerator = fileManager.enumerator(atPath: resource.path) {
                    for case let relative as String in enumerator {
                        let path = URL(fileURLWithPath: resource.path).appendingPathComponent(relative).path
                        if !isDirectory(path) {
                            result.insert(path)
                        }
                    }
                }
            } else {
                result.insert(resource.path)
            }
        }
        return Array(result)
    }

    private func assetCatalogDirectories(for target: TuistTarget) -> [String] {
        var result: Set<String> = []
        for resource in target.resources where isDirectory(resource.path) {
            if URL(fileURLWithPath: resource.path).pathExtension == "xcassets" {
                result.insert(resource.path)
                continue
            }
            if let enumerator = fileManager.enumerator(atPath: resource.path) {
                for case let relative as String in enumerator {
                    let path = URL(fileURLWithPath: resource.path).appendingPathComponent(relative).path
                    if isDirectory(path), URL(fileURLWithPath: path).pathExtension == "xcassets" {
                        result.insert(path)
                    }
                }
            }
        }
        return Array(result)
    }

    private func assetAccessors(in catalogPath: String) -> [Asset] {
        guard let enumerator = fileManager.enumerator(atPath: catalogPath) else { return [] }
        var assets: Set<Asset> = []
        for case let relative as String in enumerator {
            let url = URL(fileURLWithPath: relative)
            switch url.pathExtension {
            case "imageset", "symbolset", "spriteatlas":
                assets.insert(Asset(name: url.deletingPathExtension().lastPathComponent, kind: .image))
            case "colorset":
                assets.insert(Asset(name: url.deletingPathExtension().lastPathComponent, kind: .color))
            default:
                break
            }
        }
        return Array(assets)
    }

    private func stringTables(in files: [String]) -> [StringTable] {
        files.filter { URL(fileURLWithPath: $0).pathExtension == "strings" }.map { path in
            let url = URL(fileURLWithPath: path)
            return StringTable(
                name: url.deletingPathExtension().lastPathComponent,
                keys: parseStringsKeys(path: path)
            )
        }.filter { !$0.keys.isEmpty }
    }

    private func stringDictTables(in files: [String]) -> [StringDictTable] {
        files.filter { URL(fileURLWithPath: $0).pathExtension == "stringsdict" }.map { path in
            let url = URL(fileURLWithPath: path)
            return StringDictTable(
                name: url.deletingPathExtension().lastPathComponent,
                keys: parsePropertyListKeys(path: path)
            )
        }.filter { !$0.keys.isEmpty }
    }

    private func plistAccessors(in files: [String]) -> [PlistAccessor] {
        files.filter { URL(fileURLWithPath: $0).pathExtension == "plist" }.compactMap { path in
            let url = URL(fileURLWithPath: path)
            let keys = parsePropertyListValues(path: path).map { key, value in
                PlistKey(
                    rawName: key,
                    propertyName: swiftPropertyIdentifier(key, fallback: key),
                    swiftType: swiftType(for: value),
                    fallbackLiteral: fallbackLiteral(for: value)
                )
            }
            guard !keys.isEmpty else { return nil }
            return PlistAccessor(
                resourceName: url.deletingPathExtension().lastPathComponent,
                typeName: swiftTypeIdentifier(url.deletingPathExtension().lastPathComponent, fallback: "Plist"),
                keys: keys
            )
        }
    }

    private func fontAccessors(in files: [String]) -> [FontAccessor] {
        files.compactMap { path in
            let url = URL(fileURLWithPath: path)
            guard ["otf", "ttf", "ttc", "woff"].contains(url.pathExtension.lowercased()) else {
                return nil
            }
            let basename = url.deletingPathExtension().lastPathComponent
            let parts = basename.split(separator: "-").map(String.init)
            let familyParts = parts.count > 1 ? Array(parts.dropLast()) : [basename]
            let stylePart = parts.count > 1 ? parts.last ?? "regular" : "regular"
            return FontAccessor(
                familyName: swiftTypeIdentifier(familyParts.joined(separator: "-"), fallback: basename),
                styleName: swiftPropertyIdentifier(stylePart, fallback: stylePart),
                postscriptName: basename
            )
        }
    }

    private func parseStringsKeys(path: String) -> [String] {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8),
              let regex = try? NSRegularExpression(pattern: #"^\s*"([^"]+)"\s*="#, options: [.anchorsMatchLines]) else {
            return []
        }
        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        return regex.matches(in: content, range: range).compactMap { match in
            guard let keyRange = Range(match.range(at: 1), in: content) else { return nil }
            return String(content[keyRange])
        }
    }

    private func parsePropertyListKeys(path: String) -> [String] {
        Array(parsePropertyListValues(path: path).keys)
    }

    private func parsePropertyListValues(path: String) -> [String: Any] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let values = plist as? [String: Any] else {
            return [:]
        }
        return values
    }

    private func swiftType(for value: Any) -> String {
        switch value {
        case is Bool:
            return "Bool"
        case is Int:
            return "Int"
        case is Double, is Float:
            return "Double"
        case is Date:
            return "Date"
        case is String:
            return "String"
        default:
            return "Any"
        }
    }

    private func fallbackLiteral(for value: Any) -> String {
        switch value {
        case is Bool:
            return "false"
        case is Int:
            return "0"
        case is Double, is Float:
            return "0"
        case is Date:
            return "Date(timeIntervalSince1970: 0)"
        case is String:
            return "\"\""
        default:
            return "()"
        }
    }

    private func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

private struct ResourceInventory {
    let assets: [Asset]
    let stringTables: [StringTable]
    let stringDictTables: [StringDictTable]
    let plists: [PlistAccessor]
    let fonts: [FontAccessor]
}

private struct Asset: Hashable {
    enum Kind {
        case image
        case color
    }

    let name: String
    let kind: Kind
}

private struct StringTable {
    let name: String
    let keys: [String]
}

private struct StringDictTable {
    let name: String
    let keys: [String]
}

private struct PlistAccessor {
    let resourceName: String
    let typeName: String
    let keys: [PlistKey]
}

private struct PlistKey {
    let rawName: String
    let propertyName: String
    let swiftType: String
    let fallbackLiteral: String
}

private struct FontAccessor {
    let familyName: String
    let styleName: String
    let postscriptName: String
}

private func swiftTypeIdentifier(_ value: String, fallback: String) -> String {
    let identifier = swiftIdentifier(value, uppercaseFirst: true)
    return identifier.isEmpty ? swiftIdentifier(fallback, uppercaseFirst: true) : identifier
}

private func swiftPropertyIdentifier(_ value: String, fallback: String) -> String {
    let identifier = swiftIdentifier(value, uppercaseFirst: false)
    return identifier.isEmpty ? swiftIdentifier(fallback, uppercaseFirst: false) : identifier
}

private func swiftIdentifier(_ value: String, uppercaseFirst: Bool) -> String {
    let parts = value.split { character in
        !character.isLetter && !character.isNumber
    }.map(String.init)
    var result = parts.enumerated().map { index, part in
        if index == 0, !uppercaseFirst {
            return lowercaseFirst(part)
        }
        return uppercaseFirstCharacter(part)
    }.joined()
    if result.first?.isNumber == true {
        result = "_\(result)"
    }
    if swiftKeywords.contains(result) {
        result = "`\(result)`"
    }
    return result
}

private func uppercaseFirstCharacter(_ value: String) -> String {
    guard let first = value.first else { return value }
    return String(first).uppercased() + value.dropFirst()
}

private func lowercaseFirst(_ value: String) -> String {
    guard let first = value.first else { return value }
    return String(first).lowercased() + value.dropFirst()
}

private func escapedSwiftString(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
}

private let swiftKeywords: Set<String> = [
    "associatedtype", "class", "deinit", "enum", "extension", "fileprivate",
    "func", "import", "init", "inout", "internal", "let", "open", "operator",
    "private", "protocol", "public", "rethrows", "static", "struct", "subscript",
    "typealias", "var", "break", "case", "continue", "default", "defer", "do",
    "else", "fallthrough", "for", "guard", "if", "in", "repeat", "return",
    "switch", "where", "while", "as", "Any", "catch", "false", "is", "nil",
    "super", "self", "Self", "throw", "throws", "true", "try",
]
