import Foundation

extension BazelGenerator {
    struct ResolvedDependencies {
        var codeDeps: [BazelLabel] = []
        var pluginDeps: [BazelLabel] = []
        var appClipDeps: [BazelLabel] = []
        var frameworkDeps: [BazelLabel] = []
        var extensionDeps: [BazelLabel] = []
        var resourceDeps: [BazelLabel] = []
        var watchApplication: BazelLabel?
        var sdkFrameworks: [String] = []
        var weakSdkFrameworks: [String] = []
        var sdkDylibs: [String] = []
        var linkopts: [String] = []
        var includeDeveloperSearchPaths = false
        var testHost: BazelLabel?
    }

    struct AppSpecificExtensionConsumer {
        let wrapperName: String
        let bundleId: String
    }

    mutating func resolvedDependencies(for target: TuistTarget, packagePath: String) throws -> ResolvedDependencies {
        var result = ResolvedDependencies()
        let targetPlatform = platform(for: target)

        for dependency in target.dependencies {
            guard dependencyIsActive(dependency, for: targetPlatform) else {
                continue
            }
            if let dependencyTarget = resolveTargetDependency(dependency) {
                switch dependencyTarget.product {
                case .macro:
                    result.pluginDeps.append(try productLabel(for: dependencyTarget))
                case .framework where target.product == .app || target.product == .appClip || isExtensionProduct(target.product):
                    if let library = try libraryLabel(for: dependencyTarget) {
                        result.codeDeps.append(library)
                    }
                    result.frameworkDeps.append(try productLabel(for: dependencyTarget))
                case _ where (target.product == .app || target.product == .appClip) && isExtensionProduct(dependencyTarget.product):
                    result.extensionDeps.append(try embeddedExtensionLabel(for: dependencyTarget, app: target))
                case .appClip where target.product == .app:
                    result.appClipDeps.append(try productLabel(for: dependencyTarget))
                case .bundle:
                    if let resource = try resourceLabel(for: dependencyTarget) {
                        result.resourceDeps.append(resource)
                    }
                case .app where target.product == .unitTests || target.product == .uiTests:
                    result.testHost = try productLabel(for: dependencyTarget)
                    if let library = try libraryLabel(for: dependencyTarget) {
                        result.codeDeps.append(library)
                    }
                case .appClip where target.product == .uiTests:
                    if let hostApp = appClipHostApp(for: dependencyTarget) {
                        result.testHost = try productLabel(for: hostApp)
                    } else {
                        warnings.append("ui test target \(target.name) depends on app clip \(dependencyTarget.name), but no host app embeds it")
                    }
                    if let library = try libraryLabel(for: dependencyTarget) {
                        result.codeDeps.append(library)
                    }
                case .app where target.product == .app && targetPlatform == .ios && platform(for: dependencyTarget) == .watchOS:
                    result.watchApplication = try productLabel(for: dependencyTarget)
                default:
                    if let library = try libraryLabel(for: dependencyTarget) {
                        result.codeDeps.append(library)
                    }
                    if let resource = try resourceLabel(for: dependencyTarget), dependencyTarget.sources.isEmpty {
                        result.resourceDeps.append(resource)
                    }
                }
                continue
            }

            switch dependency {
            case let .package(product, kind):
                guard kind == .runtime else {
                    continue
                }
                if let label = localSwiftPackageProductLabels[product] {
                    result.codeDeps.append(label)
                } else if let label = remoteSwiftPackageProductLabels[product] {
                    result.codeDeps.append(label)
                } else {
                    warnings.append("package dependency \(product) on target \(target.name) is not generated yet")
                }
            case let .sdk(name, status):
                let sdkDependency = sdkDependency(for: name, status: status)
                result.sdkFrameworks.append(contentsOf: sdkDependency.sdkFrameworks)
                result.weakSdkFrameworks.append(contentsOf: sdkDependency.weakSdkFrameworks)
                result.sdkDylibs.append(contentsOf: sdkDependency.sdkDylibs)
                result.linkopts.append(contentsOf: sdkDependency.linkopts)
            case let .framework(path):
                result.codeDeps.append(BazelLabel(package: binaryImportPackage(for: path, consumingPackage: packagePath), name: binaryImportName(for: path)))
            case let .library(path, _, swiftModuleMap):
                if let swiftModuleMap {
                    let libraryImport = LibraryImport(path: path, swiftModuleMap: swiftModuleMap)
                    result.codeDeps.append(BazelLabel(package: "", name: libraryImport.importName))
                } else {
                    warnings.append("binary dependency \(path) on target \(target.name) is not generated yet")
                }
            case let .xcframework(path):
                result.codeDeps.append(BazelLabel(package: binaryImportPackage(for: path, consumingPackage: packagePath), name: xcframeworkImportName(for: path)))
            case .xctest:
                result.includeDeveloperSearchPaths = true
                result.linkopts.append(contentsOf: ["-framework", "XCTest"])
            case .target, .project:
                warnings.append("unresolved target dependency on \(target.name)")
            }
        }

        if importsXCTestUnconditionally(in: target.sources), !result.includeDeveloperSearchPaths {
            result.includeDeveloperSearchPaths = true
            result.linkopts.append(contentsOf: ["-framework", "XCTest"])
        }

        result.codeDeps.append(contentsOf: try binaryImportDepsReferencedBySources(for: target, packagePath: packagePath))
        result.codeDeps = Array(Set(result.codeDeps)).sorted()
        result.pluginDeps = Array(Set(result.pluginDeps)).sorted()
        result.appClipDeps = Array(Set(result.appClipDeps)).sorted()
        result.frameworkDeps = Array(Set(result.frameworkDeps)).sorted()
        result.extensionDeps = Array(Set(result.extensionDeps)).sorted()
        result.resourceDeps = Array(Set(result.resourceDeps)).sorted()
        result.sdkFrameworks = Array(Set(result.sdkFrameworks)).sorted()
        result.weakSdkFrameworks = Array(Set(result.weakSdkFrameworks)).sorted()
        result.sdkDylibs = Array(Set(result.sdkDylibs)).sorted()
        return result
    }

    func importsXCTestUnconditionally(in sourcePaths: [String]) -> Bool {
        sourcePaths.contains { path in
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
                return false
            }
            return importsXCTestUnconditionally(inContent: content)
        }
    }

    func importsXCTestUnconditionally(inContent content: String) -> Bool {
        var conditionalDepth = 0
        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#if") || line.hasPrefix("#elseif") || line.hasPrefix("#else") {
                if line.hasPrefix("#if") {
                    conditionalDepth += 1
                }
                continue
            }
            if line.hasPrefix("#endif") {
                conditionalDepth = max(0, conditionalDepth - 1)
                continue
            }
            if conditionalDepth == 0,
               line.range(of: #"^(?:@_exported\s+)?import\s+XCTest(?:\s|$)"#, options: .regularExpression) != nil {
                return true
            }
        }
        return false
    }

    func binaryImportDepsReferencedBySources(for target: TuistTarget, packagePath: String) throws -> [BazelLabel] {
        let imports = importedModuleNames(in: target.sources)
        guard !imports.isEmpty else {
            return []
        }

        let binaryImportsByModule = Dictionary(
            grouping: try graph.projects
                .flatMap(\.targets)
                .flatMap(\.dependencies)
                .compactMap { dependency -> (module: String, label: BazelLabel)? in
                    guard case let .xcframework(path) = dependency else {
                        return nil
                    }
                    let xcframework = try xcframeworkImport(for: path)
                    return (
                        xcframework.name,
                        BazelLabel(
                            package: binaryImportPackage(for: path, consumingPackage: packagePath),
                            name: xcframework.importName
                        )
                    )
                },
            by: \.module
        ).compactMapValues(\.first?.label)

        return imports.compactMap { binaryImportsByModule[$0] }.sorted()
    }

    func importedModuleNames(in sourcePaths: [String]) -> Set<String> {
        sourcePaths.reduce(into: Set<String>()) { result, path in
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
                return
            }
            result.formUnion(captures(pattern: #"(?m)^\s*(?:@_exported\s+)?import\s+(?:(?:class|struct|enum|protocol|func|var|typealias)\s+)?([A-Za-z_][A-Za-z0-9_]*)"#, in: content))
            result.formUnion(captures(pattern: #"@import\s+([A-Za-z_][A-Za-z0-9_]*)"#, in: content))
            result.formUnion(captures(pattern: #"#import\s+<([A-Za-z_][A-Za-z0-9_]*)/"#, in: content))
        }
    }

    func captures(pattern: String, in value: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.matches(in: value, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let matchRange = Range(match.range(at: 1), in: value) else {
                return nil
            }
            return String(value[matchRange])
        }
    }

    func firstMatch(pattern: String, in value: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, range: range),
              let matchRange = Range(match.range, in: value) else {
            return nil
        }
        return String(value[matchRange])
    }

    func replacingMatches(
        pattern: String,
        in value: String,
        options: NSRegularExpression.Options = [],
        with replacement: String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return value
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.stringByReplacingMatches(in: value, range: range, withTemplate: replacement)
    }

    func isExtensionProduct(_ product: ProductType) -> Bool {
        switch product {
        case .appExtension, .extensionKitExtension, .messagesExtension, .stickerPackExtension, .tvTopShelfExtension:
            true
        case .app, .appClip, .framework, .staticFramework, .staticLibrary, .dynamicLibrary, .macro, .bundle, .unitTests, .uiTests, .unsupported:
            false
        }
    }

    enum ApplePlatform: Hashable {
        case ios
        case macOS
        case tvOS
        case watchOS
        case visionOS

        var dependencyConditionName: String {
            switch self {
            case .ios:
                "ios"
            case .macOS:
                "macos"
            case .tvOS:
                "tvos"
            case .watchOS:
                "watchos"
            case .visionOS:
                "visionos"
            }
        }
    }

    func platform(for target: TuistTarget) -> ApplePlatform {
        let destinations = Set(target.destinations)
        let iosDestinations: Set<String> = ["iPhone", "iPad", "macWithiPadDesign"]
        if !destinations.isDisjoint(with: iosDestinations) {
            return .ios
        }
        if destinations.contains("appleTv") {
            return .tvOS
        }
        if destinations.contains("appleWatch") {
            return .watchOS
        }
        if destinations.contains("appleVision") {
            return .visionOS
        }
        if destinations.contains("mac"), destinations.isDisjoint(with: iosDestinations) {
            return .macOS
        }
        return .ios
    }

    func staticFrameworkRuleName(for platform: ApplePlatform) -> String {
        switch platform {
        case .ios:
            "ios_static_framework"
        case .macOS:
            "macos_static_framework"
        case .tvOS:
            "tvos_static_framework"
        case .watchOS:
            "watchos_static_framework"
        case .visionOS:
            "visionos_static_framework"
        }
    }

    func minimumOSVersion(for platform: ApplePlatform) -> String {
        switch platform {
        case .ios, .tvOS:
            "17.0"
        case .macOS:
            "14.0"
        case .watchOS:
            "9.0"
        case .visionOS:
            "1.0"
        }
    }

    func embeddedExtensionLabel(for extensionTarget: TuistTarget, app: TuistTarget) throws -> BazelLabel {
        if requiresAppSpecificExtensionBundle(extensionTarget, app: app) {
            return BazelLabel(
                package: try paths.packagePath(for: extensionTarget.projectPath),
                name: appSpecificExtensionName(for: extensionTarget, app: app)
            )
        }
        return try productLabel(for: extensionTarget)
    }

    func requiresAppSpecificExtensionBundle(_ extensionTarget: TuistTarget, app: TuistTarget) -> Bool {
        let appBundleId = app.bundleId ?? defaultBundleId(for: app)
        let extensionBundleId = extensionTarget.bundleId ?? defaultBundleId(for: extensionTarget)
        return !extensionBundleId.hasPrefix("\(appBundleId).")
    }

    func appSpecificExtensionName(for extensionTarget: TuistTarget, app: TuistTarget) -> String {
        "_\(sanitizedModuleName(app.name))_\(sanitizedModuleName(extensionTarget.name))"
    }

    func appSpecificExtensionBundleId(for extensionTarget: TuistTarget, app: TuistTarget) -> String {
        let appBundleId = app.bundleId ?? defaultBundleId(for: app)
        return "\(appBundleId).\(sanitizedModuleName(extensionTarget.productName))"
    }

    func resolveTargetDependency(_ dependency: TuistDependency) -> TuistTarget? {
        switch dependency {
        case let .target(name, _):
            targetsByName[name]
        case let .project(target, path, _):
            targetsByPathAndName[indexKey(path: path, name: target)] ?? targetsByName[target]
        case .framework, .xcframework, .library, .package(_, _), .sdk, .xctest:
            nil
        }
    }

    func dependencyIsActive(_ dependency: TuistDependency, for platform: ApplePlatform) -> Bool {
        guard let condition = dependencyCondition(dependency) else {
            return true
        }
        return condition.platformFilters.contains(platform.dependencyConditionName)
    }

    func dependencyCondition(_ dependency: TuistDependency) -> TuistDependencyCondition? {
        switch dependency {
        case let .target(_, condition):
            condition
        case let .project(_, _, condition):
            condition
        case .framework, .xcframework, .library, .package, .sdk, .xctest:
            nil
        }
    }

    struct SDKDependency {
        var sdkFrameworks: [String] = []
        var weakSdkFrameworks: [String] = []
        var sdkDylibs: [String] = []
        var linkopts: [String] = []
    }

    func sdkDependency(for name: String, status: String?) -> SDKDependency {
        var result = SDKDependency()
        if name.hasSuffix(".framework") {
            let framework = String(name.dropLast(".framework".count))
            if status == "optional" {
                result.weakSdkFrameworks.append(framework)
                result.linkopts.append("-Wl,-weak_framework,\(framework)")
            } else {
                result.sdkFrameworks.append(framework)
                result.linkopts.append(contentsOf: ["-framework", framework])
            }
            return result
        }

        if name.hasSuffix(".tbd") {
            let library = String(name.dropLast(".tbd".count))
            let linkerName = library.hasPrefix("lib") ? String(library.dropFirst(3)) : library
            result.sdkDylibs.append(linkerName)
            result.linkopts.append("-l\(linkerName)")
            return result
        }

        result.sdkFrameworks.append(name)
        result.linkopts.append(contentsOf: ["-framework", name])
        return result
    }

    func binaryImportName(for path: String) -> String {
        "_\(sanitizedModuleName(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent))Import"
    }

    func xcframeworkImportName(for path: String) -> String {
        "_\(sanitizedModuleName(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent))Import"
    }

    func xcframeworkImport(for path: String) throws -> XCFrameworkImport {
        try XCFrameworkImport(path: path)
    }

    struct XCFrameworkImport: Hashable {
        enum Kind {
            case dynamic
            case `static`
        }

        let path: String
        let name: String
        let kind: Kind
        let hasSwift: Bool

        init(path: String) throws {
            self.path = path
            self.name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            self.kind = try Self.kind(at: URL(fileURLWithPath: path))
            self.hasSwift = Self.containsSwiftModule(at: URL(fileURLWithPath: path))
        }

        var importName: String {
            "_\(sanitizedModuleName(name))Import"
        }

        var ruleName: String {
            switch kind {
            case .dynamic:
                "apple_dynamic_xcframework_import"
            case .static:
                "apple_static_xcframework_import"
            }
        }

        var features: [String] {
            guard hasSwift else {
                return []
            }
            switch kind {
            case .dynamic:
                return ["-swift.layering_check"]
            case .static:
                return ["-swift.layering_check", "apple._import_framework_via_swiftinterface"]
            }
        }

        static func kind(at url: URL) throws -> Kind {
            let infoURL = url.appendingPathComponent("Info.plist")
            let data = try Data(contentsOf: infoURL)
            let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
            guard let dictionary = plist as? [String: Any],
                  let libraries = dictionary["AvailableLibraries"] as? [[String: Any]],
                  let libraryPath = libraries.compactMap({ $0["LibraryPath"] as? String }).first else {
                return .dynamic
            }
            return libraryPath.hasSuffix(".a") ? .static : .dynamic
        }

        static func containsSwiftModule(at url: URL) -> Bool {
            guard let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                return false
            }
            for case let fileURL as URL in enumerator {
                if fileURL.pathExtension == "swiftmodule" || fileURL.pathExtension == "swiftinterface" {
                    return true
                }
            }
            return false
        }
    }

    struct LibraryImport: Hashable {
        let path: String
        let swiftModuleMap: String

        var name: String {
            URL(fileURLWithPath: swiftModuleMap).deletingPathExtension().lastPathComponent
        }

        var importName: String {
            "_\(sanitizedModuleName(name))Import"
        }

        var swiftInterfacePath: String {
            let moduleDirectory = URL(fileURLWithPath: swiftModuleMap)
            let preferred = moduleDirectory.appendingPathComponent("arm64-apple-ios-simulator.swiftinterface").path
            if FileManager.default.fileExists(atPath: preferred) {
                return preferred
            }
            let fallback = moduleDirectory.appendingPathComponent("x86_64-apple-ios-simulator.swiftinterface").path
            if FileManager.default.fileExists(atPath: fallback) {
                return fallback
            }
            return moduleDirectory.appendingPathComponent("\(name).swiftinterface").path
        }

        var swiftDocPath: String {
            URL(fileURLWithPath: swiftInterfacePath)
                .deletingPathExtension()
                .appendingPathExtension("swiftdoc")
                .path
        }
    }
}
