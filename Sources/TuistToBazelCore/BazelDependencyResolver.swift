import Foundation

struct BazelDependencyResolver {
    typealias ApplePlatform = BazelGenerator.ApplePlatform
    typealias ResolvedDependencies = BazelGenerator.ResolvedDependencies
    typealias SDKDependency = BazelGenerator.SDKDependency

    let graph: TuistGraph
    let paths: PathContext
    let resourceAccessors: ResourceAccessorGenerator
    let targetsByName: [String: TuistTarget]
    let targetsByPathAndName: [String: TuistTarget]
    let localSwiftPackageProductLabels: [String: BazelLabel]
    let remoteSwiftPackageProductLabels: [String: BazelLabel]
    var warnings: [String] = []

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
                case .framework where target.product == .app || target.product == .appClip || Self.isExtensionProduct(target.product):
                    if let library = try libraryLabel(for: dependencyTarget) {
                        result.codeDeps.append(library)
                    }
                    result.frameworkDeps.append(try productLabel(for: dependencyTarget))
                case _ where (target.product == .app || target.product == .appClip) && Self.isExtensionProduct(dependencyTarget.product):
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
                    result.resourceDeps.append(contentsOf: try staticRuntimeResourceLabels(for: dependencyTarget))
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
                result.codeDeps.append(BazelLabel(
                    package: binaryImportPackage(for: path, consumingPackage: packagePath),
                    name: BazelBinaryImportRenderer.name(for: path)
                ))
            case let .library(path, _, swiftModuleMap):
                if let swiftModuleMap {
                    let libraryImport = BazelLibraryImport(path: path, swiftModuleMap: swiftModuleMap)
                    result.codeDeps.append(BazelLabel(package: "", name: libraryImport.importName))
                } else {
                    warnings.append("binary dependency \(path) on target \(target.name) is not generated yet")
                }
            case let .xcframework(path):
                result.codeDeps.append(BazelLabel(
                    package: binaryImportPackage(for: path, consumingPackage: packagePath),
                    name: BazelBinaryImportRenderer.name(for: path)
                ))
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

    func staticRuntimeResourceLabels(for target: TuistTarget) throws -> [BazelLabel] {
        var visited: Set<String> = []
        return try staticRuntimeResourceLabels(for: target, visited: &visited)
    }

    private func staticRuntimeResourceLabels(
        for target: TuistTarget,
        visited: inout Set<String>
    ) throws -> [BazelLabel] {
        guard visited.insert(Self.targetIdentity(target)).inserted else {
            return []
        }

        var labels: [BazelLabel] = []
        switch target.product {
        case .bundle:
            if let resource = try resourceLabel(for: target) {
                labels.append(resource)
            }
        case .staticFramework, .staticLibrary, .dynamicLibrary:
            if let resource = try resourceLabel(for: target) {
                labels.append(resource)
            }
            let targetPlatform = platform(for: target)
            for dependency in target.dependencies where dependencyIsActive(dependency, for: targetPlatform) {
                guard let dependencyTarget = resolveTargetDependency(dependency) else {
                    continue
                }
                labels.append(contentsOf: try staticRuntimeResourceLabels(for: dependencyTarget, visited: &visited))
            }
        case .app, .appClip, .appExtension, .extensionKitExtension, .framework, .messagesExtension, .stickerPackExtension, .tvTopShelfExtension, .macro, .unitTests, .uiTests, .unsupported:
            break
        }

        return Array(Set(labels)).sorted()
    }

    func importsXCTestUnconditionally(in sourcePaths: [String]) -> Bool {
        sourcePaths.contains { path in
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
                return false
            }
            return Self.importsXCTestUnconditionally(inContent: content)
        }
    }

    static func importsXCTestUnconditionally(inContent content: String) -> Bool {
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
                    let xcframework = try BazelXCFrameworkImport(path: path)
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
            result.formUnion(Self.captures(pattern: #"(?m)^\s*(?:@_exported\s+)?import\s+(?:(?:class|struct|enum|protocol|func|var|typealias)\s+)?([A-Za-z_][A-Za-z0-9_]*)"#, in: content))
            result.formUnion(Self.captures(pattern: #"@import\s+([A-Za-z_][A-Za-z0-9_]*)"#, in: content))
            result.formUnion(Self.captures(pattern: #"#import\s+<([A-Za-z_][A-Za-z0-9_]*)/"#, in: content))
        }
    }

    static func captures(pattern: String, in value: String) -> [String] {
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

    static func firstMatch(pattern: String, in value: String) -> String? {
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

    static func replacingMatches(
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

    static func isExtensionProduct(_ product: ProductType) -> Bool {
        switch product {
        case .appExtension, .extensionKitExtension, .messagesExtension, .stickerPackExtension, .tvTopShelfExtension:
            true
        case .app, .appClip, .framework, .staticFramework, .staticLibrary, .dynamicLibrary, .macro, .bundle, .unitTests, .uiTests, .unsupported:
            false
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
            targetsByPathAndName[Self.indexKey(path: path, name: target)] ?? targetsByName[target]
        case .framework, .xcframework, .library, .package(_, _), .sdk, .xctest:
            nil
        }
    }

    func dependencyIsActive(_ dependency: TuistDependency, for platform: ApplePlatform) -> Bool {
        guard let condition = Self.dependencyCondition(dependency) else {
            return true
        }
        return condition.platformFilters.contains(platform.dependencyConditionName)
    }

    static func dependencyCondition(_ dependency: TuistDependency) -> TuistDependencyCondition? {
        switch dependency {
        case let .target(_, condition):
            condition
        case let .project(_, _, condition):
            condition
        case .framework, .xcframework, .library, .package, .sdk, .xctest:
            nil
        }
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

    func appClipHostApp(for appClip: TuistTarget) -> TuistTarget? {
        guard appClip.product == .appClip else {
            return nil
        }
        let identity = Self.targetIdentity(appClip)
        return graph.projects.flatMap(\.targets)
            .filter { $0.product == .app }
            .sorted { $0.name < $1.name }
            .first { app in
                app.dependencies.contains { dependency in
                    resolveTargetDependency(dependency).map(Self.targetIdentity) == identity
                }
            }
    }

    func binaryImportPackage(for path: String, consumingPackage: String) -> String {
        BazelBinaryImportRenderer.package(for: path, consumingPackage: consumingPackage, paths: paths)
    }

    func productLabel(for target: TuistTarget) throws -> BazelLabel {
        BazelLabel(package: try paths.packagePath(for: target.projectPath), name: target.name)
    }

    func hasSwiftLibrary(for target: TuistTarget) -> Bool {
        target.product.isSwiftBacked && (
            target.sources.contains { $0.hasSuffix(".swift") } ||
            target.sources.contains(where: Self.isClangSource) ||
            !target.headers.all.isEmpty ||
            resourceAccessors.shouldGenerate(for: target)
        )
    }

    func libraryLabel(for target: TuistTarget) throws -> BazelLabel? {
        guard hasSwiftLibrary(for: target) else { return nil }
        return BazelLabel(package: try paths.packagePath(for: target.projectPath), name: Self.libraryName(for: target))
    }

    func resourceLabel(for target: TuistTarget) throws -> BazelLabel? {
        if target.product == .bundle {
            return try productLabel(for: target)
        }
        guard !target.resources.isEmpty || !target.coreDataModels.isEmpty else { return nil }
        return BazelLabel(package: try paths.packagePath(for: target.projectPath), name: "_\(target.name)Resources")
    }

    func defaultBundleId(for target: TuistTarget) -> String {
        Self.defaultBundleId(for: target)
    }

    func platform(for target: TuistTarget) -> ApplePlatform {
        BazelGenerator.resolvePlatform(for: target)
    }

    static func libraryName(for target: TuistTarget) -> String {
        switch target.product {
        case .app, .appClip, .appExtension, .extensionKitExtension, .framework, .messagesExtension, .staticFramework, .tvTopShelfExtension, .unitTests, .uiTests:
            "\(target.name)Lib"
        case .staticLibrary, .dynamicLibrary, .macro, .bundle, .stickerPackExtension, .unsupported:
            target.name
        }
    }

    static func isClangSource(_ path: String) -> Bool {
        let supportedExtensions = ["c", "cc", "cpp", "cxx", "m", "mm"]
        return supportedExtensions.contains(URL(fileURLWithPath: path).pathExtension)
    }

    static func defaultBundleId(for target: TuistTarget) -> String {
        "dev.tuist.\(sanitizedModuleName(target.name))"
    }

    static func indexKey(path: String, name: String) -> String {
        "\(URL(fileURLWithPath: path).standardizedFileURL.path)#\(name)"
    }

    static func targetIdentity(_ target: TuistTarget) -> String {
        indexKey(path: target.projectPath, name: target.name)
    }
}
