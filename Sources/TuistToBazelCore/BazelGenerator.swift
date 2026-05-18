import Foundation

struct BazelGenerator {
    private let graph: TuistGraph
    private let paths: PathContext
    private let fileManager = FileManager.default
    private let resourceAccessors = ResourceAccessorGenerator()
    private let swiftPackageParser = SwiftPackageManifestParser()
    private var warnings: [String] = []
    private var generatedFiles: [String: String] = [:]
    private var targetsByName: [String: TuistTarget] = [:]
    private var targetsByPathAndName: [String: TuistTarget] = [:]
    private var targetsWithTestConsumers: Set<String> = []
    private var extensionSafeTargets: Set<String> = []
    private var appSpecificExtensionConsumers: [String: [AppSpecificExtensionConsumer]] = [:]
    private var localSwiftPackageManifests: [String: SwiftPackageManifest] = [:]
    private var localSwiftPackageProductLabels: [String: BazelLabel] = [:]
    private var remoteSwiftPackageRepositories: [String] = []
    private var remoteSwiftPackageProductLabels: [String: BazelLabel] = [:]

    init(graph: TuistGraph, paths: PathContext) {
        self.graph = graph
        self.paths = paths
    }

    mutating func render() throws -> (files: [String: String], warnings: [String]) {
        indexTargets()
        try indexLocalSwiftPackages()
        try indexRemoteSwiftPackages()
        try renderRemoteSwiftPackageSupportFiles()
        var files: [String: String] = [:]
        files["MODULE.bazel"] = renderModule()
        let rootXcodeproj = try renderRootXcodeproj()

        let targetsByPackage = try Dictionary(grouping: graph.projects.flatMap(\.targets)) { target in
            try paths.packagePath(for: target.projectPath)
        }

        files["BUILD.bazel"] = try renderPackageBuild(
            packagePath: "",
            targets: targetsByPackage[""] ?? [],
            extraLoads: rootXcodeproj.loads,
            extraBlocks: [rootXcodeproj.block]
        )
        for packagePath in targetsByPackage.keys.sorted() {
            guard !packagePath.isEmpty else { continue }
            files[pathForBuildFile(packagePath)] = try renderPackageBuild(
                packagePath: packagePath,
                targets: targetsByPackage[packagePath] ?? []
            )
        }
        for packagePath in localSwiftPackageManifests.keys.sorted() {
            let buildPath = pathForBuildFile(packagePath)
            guard files[buildPath] == nil else {
                warnings.append("local Swift package at \(packagePath) overlaps an existing Bazel package")
                continue
            }
            files[buildPath] = try renderLocalSwiftPackageBuild(
                packagePath: packagePath,
                manifest: localSwiftPackageManifests[packagePath]!
            )
        }
        for (path, content) in generatedFiles {
            files[path] = content
        }

        return (files, warnings)
    }

    private mutating func indexTargets() {
        for target in graph.projects.flatMap(\.targets) {
            targetsByName[target.name] = target
            targetsByPathAndName[indexKey(path: target.projectPath, name: target.name)] = target
        }

        for target in graph.projects.flatMap(\.targets) where target.product == .unitTests || target.product == .uiTests {
            for dependency in target.dependencies {
                if let resolved = resolveTargetDependency(dependency) {
                    targetsWithTestConsumers.insert(resolved.name)
                }
            }
        }

        for target in graph.projects.flatMap(\.targets) where isExtensionProduct(target.product) {
            for dependency in target.dependencies {
                if let resolved = resolveTargetDependency(dependency),
                   resolved.product == .framework || resolved.product == .staticFramework {
                    extensionSafeTargets.insert(targetIdentity(resolved))
                }
            }
        }

        for app in graph.projects.flatMap(\.targets) where app.product == .app {
            for dependency in app.dependencies {
                guard let extensionTarget = resolveTargetDependency(dependency),
                      isExtensionProduct(extensionTarget.product),
                      requiresAppSpecificExtensionBundle(extensionTarget, app: app) else {
                    continue
                }
                let consumer = AppSpecificExtensionConsumer(
                    wrapperName: appSpecificExtensionName(for: extensionTarget, app: app),
                    bundleId: appSpecificExtensionBundleId(for: extensionTarget, app: app)
                )
                let identity = targetIdentity(extensionTarget)
                if appSpecificExtensionConsumers[identity]?.contains(where: { $0.wrapperName == consumer.wrapperName }) != true {
                    appSpecificExtensionConsumers[identity, default: []].append(consumer)
                }
            }
        }
    }

    private func indexKey(path: String, name: String) -> String {
        "\(URL(fileURLWithPath: path).standardizedFileURL.path)#\(name)"
    }

    private func targetIdentity(_ target: TuistTarget) -> String {
        indexKey(path: target.projectPath, name: target.name)
    }

    private mutating func indexLocalSwiftPackages() throws {
        for localPackage in graph.localSwiftPackages {
            let packagePath = try paths.packagePath(for: localPackage.path)
            guard localSwiftPackageManifests[packagePath] == nil else {
                continue
            }
            let manifest = try swiftPackageParser.parse(packagePath: localPackage.path)
            localSwiftPackageManifests[packagePath] = manifest

            let targetNames = localSwiftPackageTargetNamesToGenerate(manifest)
            for product in manifest.products {
                guard let targetName = product.targets.first, product.targets.count == 1, targetNames.contains(targetName) else {
                    warnings.append("local Swift package product \(product.name) is not generated because it has multiple or missing targets")
                    continue
                }
                let label = BazelLabel(package: packagePath, name: targetName)
                if localSwiftPackageProductLabels[product.name] == nil {
                    localSwiftPackageProductLabels[product.name] = label
                } else {
                    warnings.append("local Swift package product \(product.name) is ambiguous")
                }
            }

            for target in manifest.targets where targetNames.contains(target.name) {
                localSwiftPackageProductLabels[target.name] = BazelLabel(package: packagePath, name: target.name)
            }
            for target in manifest.binaryTargets where targetNames.contains(target.name) {
                localSwiftPackageProductLabels[target.name] = BazelLabel(package: packagePath, name: target.name)
            }
        }
    }

    private mutating func indexRemoteSwiftPackages() throws {
        remoteSwiftPackageRepositories = orderedUnique(
            allRemoteSwiftPackages().map { remoteSwiftPackageRepositoryName(for: $0.url) }
        ).sorted()

        let packageDependencyProducts = graph.projects
            .flatMap(\.targets)
            .flatMap(\.dependencies)
            .compactMap { dependency -> String? in
                guard case let .package(product, kind) = dependency, kind == .runtime else {
                    return nil
                }
                return product
            }
        let localPackageDependencyProducts = localSwiftPackageManifests.values
            .flatMap(\.targets)
            .flatMap(\.packageDependencies)

        guard allRemoteSwiftPackages().count == 1,
              let repository = remoteSwiftPackageRepositories.first else {
            if allRemoteSwiftPackages().count > 1 {
                warnings.append("remote Swift package products are not generated because product-to-package mapping is ambiguous")
            }
            return
        }

        for product in orderedUnique(packageDependencyProducts + localPackageDependencyProducts) where localSwiftPackageProductLabels[product] == nil {
            remoteSwiftPackageProductLabels[product] = BazelLabel(package: "@\(repository)", name: product)
        }
    }

    private mutating func renderRemoteSwiftPackageSupportFiles() throws {
        guard !allRemoteSwiftPackages().isEmpty else {
            return
        }

        generatedFiles[".bazel/SwiftPackages/Package.swift"] = renderRemoteSwiftPackageManifest()
        guard let resolvedURL = swiftPackageResolvedURL() else {
            warnings.append("remote Swift packages require Package.resolved, but none was found")
            return
        }
        let resolved = try String(contentsOf: resolvedURL, encoding: .utf8)
        generatedFiles[".bazel/SwiftPackages/Package.resolved"] = try normalizedPackageResolved(resolved)
    }

    private func pathForBuildFile(_ packagePath: String) -> String {
        packagePath.isEmpty ? "BUILD.bazel" : "\(packagePath)/BUILD.bazel"
    }

    private func renderModule() -> String {
        let base = """
        bazel_dep(
            name = "rules_xcodeproj",
            version = "4.0.0",
        )
        bazel_dep(
            name = "apple_support",
            version = "2.5.0",
            repo_name = "build_bazel_apple_support",
        )
        bazel_dep(
            name = "rules_apple",
            version = "4.5.2",
            repo_name = "build_bazel_rules_apple",
        )
        bazel_dep(
            name = "rules_swift",
            version = "3.5.0",
            repo_name = "build_bazel_rules_swift",
        )
        bazel_dep(
            name = "rules_cc",
            version = "0.2.17",
        )
        bazel_dep(
            name = "rules_ios",
            version = "6.0.1",
            repo_name = "build_bazel_rules_ios",
        )
        bazel_dep(name = "gazelle", version = "0.48.0")
        bazel_dep(name = "rules_swift_package_manager", version = "1.13.0")
        """
        guard !remoteSwiftPackageRepositories.isEmpty else {
            return base
        }

        let repositories = remoteSwiftPackageRepositories
            .map { "    \(Starlark.quote($0))," }
            .joined(separator: "\n")
        return """
        \(base)

        swift_deps = use_extension(
            "@rules_swift_package_manager//:extensions.bzl",
            "swift_deps",
        )
        swift_deps.from_package(
            declare_swift_package = False,
            resolved = "//:.bazel/SwiftPackages/Package.resolved",
            swift = "//:.bazel/SwiftPackages/Package.swift",
        )
        use_repo(
            swift_deps,
        \(repositories)
        )
        """
    }

    private func renderRemoteSwiftPackageManifest() -> String {
        let dependencies = allRemoteSwiftPackages()
            .sorted { $0.url < $1.url }
            .map { remotePackage in
                "        .package(url: \(Starlark.quote(remotePackage.url)), \(remotePackage.requirement.packageDescriptionExpression)),"
            }
            .joined(separator: "\n")

        return """
        // swift-tools-version: 5.9
        import PackageDescription

        let package = Package(
            name: "TuistToBazelDependencies",
            dependencies: [
        \(dependencies)
            ]
        )
        """
    }

    private func swiftPackageResolvedURL() -> URL? {
        [
            paths.root.appendingPathComponent("Package.resolved"),
            paths.root.appendingPathComponent(".package.resolved"),
            paths.root.appendingPathComponent("Tuist/Package.resolved"),
        ].first { fileManager.fileExists(atPath: $0.path) }
            ?? localSwiftPackageManifests.values
                .map { URL(fileURLWithPath: $0.packagePath).appendingPathComponent("Package.resolved") }
                .first { fileManager.fileExists(atPath: $0.path) }
    }

    private func normalizedPackageResolved(_ content: String) throws -> String {
        let data = Data(content.utf8)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["version"] as? NSNumber)?.intValue == 1,
              let object = root["object"] as? [String: Any],
              let pins = object["pins"] as? [[String: Any]] else {
            return content
        }

        let normalizedPins = pins.compactMap { pin -> [String: Any]? in
            guard let package = pin["package"] as? String,
                  let location = pin["repositoryURL"] as? String,
                  let state = pin["state"] as? [String: Any] else {
                return nil
            }
            var normalizedState: [String: Any] = [:]
            for key in ["branch", "revision", "version"] {
                guard let value = state[key], !(value is NSNull) else {
                    continue
                }
                normalizedState[key] = value
            }
            return [
                "identity": packageIdentityName(for: package),
                "kind": "remoteSourceControl",
                "location": location,
                "state": normalizedState,
            ]
        }

        let normalized: [String: Any] = [
            "pins": normalizedPins,
            "version": 2,
        ]
        let normalizedData = try JSONSerialization.data(withJSONObject: normalized, options: [.prettyPrinted, .sortedKeys])
        return String(data: normalizedData, encoding: .utf8) ?? content
    }

    private func remoteSwiftPackageRepositoryName(for url: String) -> String {
        let trimmed = url.hasSuffix(".git") ? String(url.dropLast(4)) : url
        let lastComponent = URL(string: trimmed)?.lastPathComponent
            ?? trimmed.split(separator: "/").last.map(String.init)
            ?? trimmed
        return "swiftpkg_\(packageIdentityName(for: lastComponent))"
    }

    private func packageIdentityName(for value: String) -> String {
        sanitizedModuleName(value.lowercased())
    }

    private func allRemoteSwiftPackages() -> [TuistRemoteSwiftPackage] {
        var seen: Set<TuistRemoteSwiftPackage> = []
        return (graph.remoteSwiftPackages + localSwiftPackageManifests.values.flatMap(\.remotePackages))
            .filter { seen.insert($0).inserted }
    }

    private func orderedUnique<T: Hashable>(_ values: [T]) -> [T] {
        var seen: Set<T> = []
        return values.filter { seen.insert($0).inserted }
    }

    private mutating func renderRootXcodeproj() throws -> (loads: [String], block: String) {
        let primaryProducts = graph.projects.flatMap(\.targets)
            .filter { target in
                target.product == .app
            }
            .sorted { $0.name < $1.name }
        let topLevelProducts = try primaryProducts.isEmpty
            ? graph.projects.flatMap(\.targets)
                .filter { target in
                    try paths.packagePath(for: target.projectPath).isEmpty && isLibraryTopLevelProduct(target.product)
                }
                .sorted { $0.name < $1.name }
            : primaryProducts
        guard !topLevelProducts.isEmpty else {
            warnings.append("no top-level product found; root xcodeproj was skipped")
            return (
                loads: [],
                block: "# xcodeproj skipped: no top-level product"
            )
        }

        let topLevelTargets = try topLevelProducts.map { app in
            """
                    top_level_target(
                        "\(try productLabel(for: app).description)",
                        target_environments = ["simulator"],
                    )
            """
        }.joined(separator: ",\n")
        return (
            loads: [
                "load(\"@rules_xcodeproj//xcodeproj:defs.bzl\", \"top_level_target\")",
                "load(\"@rules_xcodeproj//xcodeproj:xcodeproj.bzl\", \"xcodeproj\")",
            ],
            block: """
            xcodeproj(
                name = "xcodeproj",
                project_name = "\(sanitizedModuleName(graph.name))",
                scheme_autogeneration_mode = "all",
                top_level_targets = [
            \(topLevelTargets),
                ],
            )
            """
        )
    }

    private func isLibraryTopLevelProduct(_ product: ProductType) -> Bool {
        switch product {
        case .framework, .staticFramework, .dynamicLibrary, .staticLibrary:
            true
        case .app, .appExtension, .extensionKitExtension, .messagesExtension, .stickerPackExtension, .tvTopShelfExtension, .macro, .bundle, .unitTests, .uiTests, .unsupported:
            false
        }
    }

    private mutating func renderPackageBuild(
        packagePath: String,
        targets: [TuistTarget],
        extraLoads: [String] = [],
        extraBlocks: [String] = []
    ) throws -> String {
        var build = BuildFile()
        let loads = orderedUnique(try loadsFor(targets, packagePath: packagePath) + extraLoads)
        for load in loads {
            build.add(load)
        }
        if !loads.isEmpty {
            build.add()
        }
        build.add("package(default_visibility = [\"//visibility:public\"])")

        let binaryImports = try renderBinaryImports(packagePath: packagePath, targets: targets)
        for binaryImport in binaryImports {
            build.add()
            build.addBlock(binaryImport)
        }

        for target in targets.sorted(by: { $0.name < $1.name }) {
            build.add()
            build.addBlock(try renderTarget(target, packagePath: packagePath))
        }
        for block in extraBlocks {
            build.add()
            build.addBlock(block)
        }

        return build.content
    }

    private func renderLocalSwiftPackageBuild(packagePath: String, manifest: SwiftPackageManifest) throws -> String {
        var build = BuildFile()
        let targetNames = localSwiftPackageTargetNamesToGenerate(manifest)
        let buildableTargets = manifest.targets.filter { targetNames.contains($0.name) && !$0.sources.isEmpty }
        let binaryImports = try manifest.binaryTargets
            .filter { targetNames.contains($0.name) }
            .map { try (target: $0, xcframework: xcframeworkImport(for: $0.path)) }
        if !buildableTargets.isEmpty {
            build.add("load(\"@build_bazel_rules_swift//swift:swift.bzl\", \"swift_library\")")
        }
        if !binaryImports.isEmpty {
            let ruleNames = Set(binaryImports.map(\.xcframework.ruleName)).sorted().map(Starlark.quote).joined(separator: ", ")
            build.add("load(\"@build_bazel_rules_apple//apple:apple.bzl\", \(ruleNames))")
        }
        if !buildableTargets.isEmpty || !binaryImports.isEmpty {
            build.add()
        }
        build.add("package(default_visibility = [\"//visibility:public\"])")

        for binaryImport in binaryImports.sorted(by: { $0.target.name < $1.target.name }) {
            let relative = try paths.pathRelativeToPackage(binaryImport.target.path, packagePath: packagePath)
            let featuresAttribute = binaryImport.xcframework.features.isEmpty ? "" : "    features = \(Starlark.list(binaryImport.xcframework.features, indent: 4)),\n"
            build.add()
            build.addBlock("""
            \(binaryImport.xcframework.ruleName)(
                name = "\(binaryImport.target.name)",
            \(featuresAttribute)    xcframework_imports = glob([\(Starlark.quote(relative + "/**"))]),
            )
            """)
        }

        for target in buildableTargets.sorted(by: { $0.name < $1.name }) {
            let sourceLabels = try target.sources.map {
                try paths.pathRelativeToPackage($0, packagePath: packagePath)
            }
            let deps = target.dependencies
                .filter(targetNames.contains)
                .map { BazelLabel(package: packagePath, name: $0) }
                + target.packageDependencies.compactMap { remoteSwiftPackageProductLabels[$0] }
            build.add()
            build.addBlock("""
            swift_library(
                name = "\(target.name)",
                srcs = \(Starlark.list(sourceLabels, indent: 4)),
                module_name = "\(sanitizedModuleName(target.name))",
                deps = \(Starlark.list(deps.map { $0.localDescription(in: packagePath) }, indent: 4)),
            )
            """)
        }

        for product in manifest.products.sorted(by: { $0.name < $1.name }) {
            guard let targetName = product.targets.first,
                  product.targets.count == 1,
                  product.name != targetName,
                  targetNames.contains(targetName) else {
                continue
            }
            build.add()
            build.addBlock("""
            alias(
                name = "\(product.name)",
                actual = ":\(targetName)",
            )
            """)
        }

        return build.content
    }

    private func localSwiftPackageTargetNamesToGenerate(_ manifest: SwiftPackageManifest) -> Set<String> {
        let targetsByName = Dictionary(uniqueKeysWithValues: manifest.targets.map { ($0.name, $0) })
        let binaryTargetNames = Set(manifest.binaryTargets.map(\.name))
        let allTargetNames = Set(targetsByName.keys).union(binaryTargetNames)
        var included: Set<String> = []
        var pending = manifest.products.flatMap(\.targets)

        while let name = pending.popLast() {
            guard allTargetNames.contains(name), included.insert(name).inserted else {
                continue
            }
            if let target = targetsByName[name] {
                pending.append(contentsOf: target.dependencies)
            }
        }

        return included
    }

    private func loadsFor(_ targets: [TuistTarget], packagePath: String) throws -> [String] {
        var iosRules: Set<String> = []
        var macOSRules: Set<String> = []
        var tvOSRules: Set<String> = []
        var watchOSRules: Set<String> = []
        var swiftRules: Set<String> = []
        var needsMixedLanguage = false
        var needsObjC = false
        var needsResources = false
        var appleImportRules: Set<String> = []

        for target in targets {
            if target.product == .macro {
                swiftRules.insert("swift_compiler_plugin")
            } else if target.product.isSwiftBacked {
                if requiresMixedLanguage(target) {
                    needsMixedLanguage = true
                } else if requiresObjCLibrary(target) {
                    needsObjC = true
                } else {
                    swiftRules.insert("swift_library")
                }
            }
            needsResources = needsResources || !target.resources.isEmpty || target.product == .bundle
            switch target.product {
            case .app:
                switch platform(for: target) {
                case .tvOS:
                    tvOSRules.insert("tvos_application")
                case .watchOS:
                    watchOSRules.insert("watchos_application")
                case .ios, .macOS:
                    iosRules.insert("ios_application")
                }
            case .appExtension:
                switch platform(for: target) {
                case .ios:
                    iosRules.insert("ios_extension")
                case .macOS:
                    macOSRules.insert("macos_extension")
                case .tvOS:
                    tvOSRules.insert("tvos_extension")
                case .watchOS:
                    watchOSRules.insert("watchos_extension")
                }
            case .extensionKitExtension:
                switch platform(for: target) {
                case .ios:
                    iosRules.insert("ios_extension")
                case .macOS:
                    macOSRules.insert("macos_extension")
                case .tvOS:
                    tvOSRules.insert("tvos_extension")
                case .watchOS:
                    watchOSRules.insert("watchos_extension")
                }
            case .framework:
                switch platform(for: target) {
                case .ios:
                    iosRules.insert("ios_framework")
                case .macOS:
                    macOSRules.insert("macos_framework")
                case .tvOS:
                    tvOSRules.insert("tvos_framework")
                case .watchOS:
                    watchOSRules.insert("watchos_framework")
                }
            case .messagesExtension:
                iosRules.insert("ios_imessage_extension")
            case .staticFramework:
                iosRules.insert("ios_static_framework")
            case .stickerPackExtension:
                iosRules.insert("ios_sticker_pack_extension")
            case .tvTopShelfExtension:
                tvOSRules.insert("tvos_extension")
            case .macro:
                break
            case .unitTests:
                switch platform(for: target) {
                case .ios:
                    iosRules.insert("ios_unit_test")
                case .macOS:
                    macOSRules.insert("macos_unit_test")
                case .tvOS:
                    tvOSRules.insert("tvos_unit_test")
                case .watchOS:
                    watchOSRules.insert("watchos_unit_test")
                }
            case .uiTests:
                iosRules.insert("ios_ui_test")
            case .staticLibrary, .dynamicLibrary, .bundle, .unsupported:
                break
            }
        }

        let dependencyPairs = try dependenciesWithConsumingPackages(for: packagePath, targets: targets)
        for pair in dependencyPairs {
            for dependency in pair.dependencies {
                switch dependency {
                case let .framework(path):
                    if binaryImportPackage(for: path, consumingPackage: pair.packagePath) == packagePath {
                        appleImportRules.insert("apple_static_framework_import")
                    }
                case let .xcframework(path):
                    if binaryImportPackage(for: path, consumingPackage: pair.packagePath) == packagePath {
                        appleImportRules.insert(try xcframeworkImport(for: path).ruleName)
                    }
                case let .library(_, _, swiftModuleMap):
                    if swiftModuleMap != nil,
                       binaryImportPackage(for: dependency, consumingPackage: pair.packagePath) == packagePath {
                        swiftRules.insert("swift_import")
                    }
                case .target, .project, .package(_, _), .sdk, .xctest:
                    break
                }
            }
        }

        var loads: [String] = []
        if !swiftRules.isEmpty {
            let ruleNames = swiftRules.sorted().map(Starlark.quote).joined(separator: ", ")
            loads.append("load(\"@build_bazel_rules_swift//swift:swift.bzl\", \(ruleNames))")
        }
        if needsMixedLanguage {
            loads.append("load(\"@build_bazel_rules_swift//mixed_language:mixed_language_library.bzl\", \"mixed_language_library\")")
        }
        if needsObjC {
            loads.append("load(\"@rules_cc//cc:objc_library.bzl\", \"objc_library\")")
        }
        if !appleImportRules.isEmpty {
            let ruleNames = appleImportRules.sorted().map(Starlark.quote).joined(separator: ", ")
            loads.append("load(\"@build_bazel_rules_apple//apple:apple.bzl\", \(ruleNames))")
        }
        if !iosRules.isEmpty {
            let ruleNames = iosRules.sorted().map(Starlark.quote).joined(separator: ", ")
            loads.append("load(\"@build_bazel_rules_apple//apple:ios.bzl\", \(ruleNames))")
        }
        if !macOSRules.isEmpty {
            let ruleNames = macOSRules.sorted().map(Starlark.quote).joined(separator: ", ")
            loads.append("load(\"@build_bazel_rules_apple//apple:macos.bzl\", \(ruleNames))")
        }
        if !tvOSRules.isEmpty {
            let ruleNames = tvOSRules.sorted().map(Starlark.quote).joined(separator: ", ")
            loads.append("load(\"@build_bazel_rules_apple//apple:tvos.bzl\", \(ruleNames))")
        }
        if !watchOSRules.isEmpty {
            let ruleNames = watchOSRules.sorted().map(Starlark.quote).joined(separator: ", ")
            loads.append("load(\"@build_bazel_rules_apple//apple:watchos.bzl\", \(ruleNames))")
        }
        if needsResources {
            loads.append("load(\"@build_bazel_rules_apple//apple:resources.bzl\", \"apple_bundle_import\", \"apple_resource_bundle\", \"apple_resource_group\")")
        }
        return loads
    }

    private func renderBinaryImports(packagePath: String, targets: [TuistTarget]) throws -> [String] {
        let dependencyPairs = try dependenciesWithConsumingPackages(for: packagePath, targets: targets)
        let frameworkPaths = Set(dependencyPairs.flatMap { pair in
            pair.dependencies.compactMap { dependency -> String? in
                if case let .framework(path) = dependency,
                   binaryImportPackage(for: path, consumingPackage: pair.packagePath) == packagePath {
                    return path
                }
                return nil
            }
        })
        let libraryImports = Dictionary(
            grouping: dependencyPairs.flatMap { pair in
                pair.dependencies.compactMap { dependency -> LibraryImport? in
                    if case let .library(path, _, swiftModuleMap) = dependency,
                       let swiftModuleMap,
                       binaryImportPackage(for: dependency, consumingPackage: pair.packagePath) == packagePath {
                        return LibraryImport(path: path, swiftModuleMap: swiftModuleMap)
                    }
                    return nil
                }
            },
            by: \.name
        ).values.compactMap(\.first)
        let xcframeworkImports = Dictionary(
            grouping: try dependencyPairs.flatMap { pair in
                try pair.dependencies.compactMap { dependency -> XCFrameworkImport? in
                    if case let .xcframework(path) = dependency,
                       binaryImportPackage(for: path, consumingPackage: pair.packagePath) == packagePath {
                        return try xcframeworkImport(for: path)
                    }
                    return nil
                }
            },
            by: \.name
        ).values.compactMap(\.first)

        let frameworkImports = try frameworkPaths.sorted().map { path in
            let relative = try paths.pathRelativeToPackage(path, packagePath: packagePath)
            return """
            apple_static_framework_import(
                name = "\(binaryImportName(for: path))",
                framework_imports = glob([\(Starlark.quote(relative + "/**"))]),
                tags = ["manual"],
            )
            """
        }
        let xcframeworkRules = try xcframeworkImports.sorted(by: { $0.name < $1.name }).map { xcframeworkImport in
            let relative = try paths.pathRelativeToPackage(xcframeworkImport.path, packagePath: packagePath)
            let featuresAttribute = xcframeworkImport.features.isEmpty ? "" : "    features = \(Starlark.list(xcframeworkImport.features, indent: 4)),\n"
            return """
            \(xcframeworkImport.ruleName)(
                name = "\(xcframeworkImport.importName)",
            \(featuresAttribute)    tags = ["manual"],
                xcframework_imports = glob([\(Starlark.quote(relative + "/**"))]),
            )
            """
        }
        let swiftImports = try libraryImports.sorted(by: { $0.name < $1.name }).map { libraryImport in
            let archive = try paths.pathRelativeToPackage(libraryImport.path, packagePath: packagePath)
            let swiftInterface = try paths.pathRelativeToPackage(libraryImport.swiftInterfacePath, packagePath: packagePath)
            let swiftDoc = try paths.pathRelativeToPackage(libraryImport.swiftDocPath, packagePath: packagePath)
            return """
            swift_import(
                name = "\(libraryImport.importName)",
                archives = [\(Starlark.quote(archive))],
                module_name = "\(libraryImport.name)",
                swiftdoc = \(Starlark.quote(swiftDoc)),
                swiftinterface = \(Starlark.quote(swiftInterface)),
                tags = ["manual"],
            )
            """
        }

        return frameworkImports + xcframeworkRules + swiftImports
    }

    private func dependenciesWithConsumingPackages(
        for packagePath: String,
        targets: [TuistTarget]
    ) throws -> [(packagePath: String, dependencies: [TuistDependency])] {
        let dependencyTargets = packagePath.isEmpty ? graph.projects.flatMap(\.targets) : targets
        return try dependencyTargets.map { target in
            (try paths.packagePath(for: target.projectPath), target.dependencies)
        }
    }

    private func binaryImportPackage(for dependency: TuistDependency, consumingPackage: String) -> String? {
        switch dependency {
        case let .framework(path):
            binaryImportPackage(for: path, consumingPackage: consumingPackage)
        case let .xcframework(path):
            binaryImportPackage(for: path, consumingPackage: consumingPackage)
        case .library:
            ""
        case .target, .project, .package(_, _), .sdk, .xctest:
            nil
        }
    }

    private func binaryImportPackage(for path: String, consumingPackage: String) -> String {
        guard let relative = try? paths.pathRelativeToPackage(path, packagePath: consumingPackage),
              relative != "..",
              !relative.hasPrefix("../") else {
            return ""
        }
        return consumingPackage
    }

    private mutating func renderTarget(_ target: TuistTarget, packagePath: String) throws -> String {
        switch target.product {
        case .app:
            return try renderApp(target, packagePath: packagePath)
        case .appExtension, .extensionKitExtension:
            let original = try renderExtension(target, packagePath: packagePath)
            return try renderWithAppSpecificExtensionBundles(
                target,
                packagePath: packagePath,
                original: original
            )
        case .framework:
            return try renderFramework(target, packagePath: packagePath)
        case .messagesExtension:
            let original = try renderMessagesExtension(target, packagePath: packagePath)
            return try renderWithAppSpecificExtensionBundles(
                target,
                packagePath: packagePath,
                original: original
            )
        case .staticFramework:
            return try renderStaticFramework(target, packagePath: packagePath)
        case .stickerPackExtension:
            let original = try renderStickerPackExtension(target, packagePath: packagePath)
            return try renderWithAppSpecificExtensionBundles(
                target,
                packagePath: packagePath,
                original: original
            )
        case .tvTopShelfExtension:
            let original = try renderTVTopShelfExtension(target, packagePath: packagePath)
            return try renderWithAppSpecificExtensionBundles(
                target,
                packagePath: packagePath,
                original: original
            )
        case .staticLibrary, .dynamicLibrary:
            return try renderLibrary(target, packagePath: packagePath)
        case .macro:
            return try renderCompilerPlugin(target, packagePath: packagePath)
        case .bundle:
            return try renderResourceBundle(target, packagePath: packagePath)
        case .unitTests:
            return try renderUnitTest(target, packagePath: packagePath)
        case .uiTests:
            warnings.append("ui test target \(target.name) is decoded but not generated yet")
            return "# \(target.name) skipped: ui test generation is not implemented yet"
        case .unsupported:
            warnings.append("target \(target.name) has an unsupported product and was skipped")
            return "# \(target.name) skipped: unsupported product"
        }
    }

    private mutating func renderApp(_ target: TuistTarget, packagePath: String) throws -> String {
        let deps = try resolvedDependencies(for: target, packagePath: packagePath)
        let platform = platform(for: target)
        let ruleName: String
        let families: String
        switch platform {
        case .tvOS:
            ruleName = "tvos_application"
            families = "    families = [\"tv\"],\n"
        case .watchOS:
            ruleName = "watchos_application"
            families = ""
        case .ios, .macOS:
            ruleName = "ios_application"
            families = "    families = [\"iphone\", \"ipad\"],\n"
        }
        return [
            try renderResourceGroupIfNeeded(target, packagePath: packagePath),
            try renderSwiftLibrary(target, packagePath: packagePath, name: libraryName(for: target), testonly: false, manual: true, resolved: deps),
            """
            \(ruleName)(
                name = "\(target.name)",
                bundle_id = "\(target.bundleId ?? defaultBundleId(for: target))",
            \(families)\(infoplistsAttribute(target, packagePath: packagePath, indent: 4))    minimum_os_version = "\(minimumOSVersion(for: platform))",
                deps = [":\(libraryName(for: target))"],
            \(optionalLabelListAttribute("frameworks", deps.frameworkDeps, packagePath: packagePath, indent: 4))\(optionalLabelAttribute("watch_application", deps.watchApplication, packagePath: packagePath, indent: 4))\(optionalLabelListAttribute("extensions", deps.extensionDeps, packagePath: packagePath, indent: 4))\(optionalLabelListAttribute("resources", deps.resourceDeps + resourceGroupLabelIfNeeded(target, packagePath: packagePath), packagePath: packagePath, indent: 4)))
            """
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n\n")
            .replacingOccurrences(of: ")\n \n", with: ")\n")
    }

    private mutating func renderExtension(_ target: TuistTarget, packagePath: String) throws -> String {
        let platform = platform(for: target)
        let ruleName: String
        switch platform {
        case .ios:
            ruleName = "ios_extension"
        case .macOS:
            ruleName = "macos_extension"
        case .tvOS:
            ruleName = "tvos_extension"
        case .watchOS:
            ruleName = "watchos_extension"
        }
        return try renderExtensionRule(
            target,
            packagePath: packagePath,
            ruleName: ruleName,
            extraAttributes: extensionExtraAttributes(for: target, platform: platform)
        )
    }

    private mutating func renderMessagesExtension(_ target: TuistTarget, packagePath: String) throws -> String {
        try renderExtensionRule(target, packagePath: packagePath, ruleName: "ios_imessage_extension")
    }

    private mutating func renderExtensionRule(
        _ target: TuistTarget,
        packagePath: String,
        ruleName: String,
        extraAttributes: String = ""
    ) throws -> String {
        let deps = try resolvedDependencies(for: target, packagePath: packagePath)
        let platform = platform(for: target)
        return [
            try renderResourceGroupIfNeeded(target, packagePath: packagePath),
            try renderSwiftLibrary(target, packagePath: packagePath, name: libraryName(for: target), testonly: false, manual: true, resolved: deps),
            renderExtensionBundleRule(
                target,
                packagePath: packagePath,
                deps: deps,
                platform: platform,
                ruleName: ruleName,
                name: target.name,
                bundleId: target.bundleId ?? defaultBundleId(for: target),
                infoPlistTarget: target,
                extraAttributes: extraAttributes
            ),
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n\n")
            .replacingOccurrences(of: ")\n \n", with: ")\n")
    }

    private mutating func renderExtensionBundleRule(
        _ target: TuistTarget,
        packagePath: String,
        deps: ResolvedDependencies,
        platform: ApplePlatform,
        ruleName: String,
        name: String,
        bundleId: String,
        infoPlistTarget: TuistTarget,
        extraAttributes: String = ""
    ) -> String {
        let executableName = name == target.productName ? "" : "    executable_name = \"\(target.productName)\",\n"
        return """
        \(ruleName)(
            name = "\(name)",
            bundle_id = "\(bundleId)",
        \(executableName)\(extraAttributes)\(familiesAttribute(for: platform, indent: 4))\(infoplistsAttribute(infoPlistTarget, packagePath: packagePath, indent: 4))    minimum_os_version = "\(minimumOSVersion(for: platform))",
            deps = [":\(libraryName(for: target))"],
        \(optionalLabelListAttribute("frameworks", deps.frameworkDeps, packagePath: packagePath, indent: 4))\(optionalLabelListAttribute("resources", deps.resourceDeps + resourceGroupLabelIfNeeded(target, packagePath: packagePath), packagePath: packagePath, indent: 4)))
        """
    }

    private mutating func renderWithAppSpecificExtensionBundles(
        _ target: TuistTarget,
        packagePath: String,
        original: String
    ) throws -> String {
        let identity = targetIdentity(target)
        let consumers = appSpecificExtensionConsumers[identity, default: []].sorted { $0.wrapperName < $1.wrapperName }
        guard !consumers.isEmpty else {
            return original
        }

        let wrappers = try consumers.map { consumer in
            try renderAppSpecificExtensionBundle(target, packagePath: packagePath, consumer: consumer)
        }
        return ([original] + wrappers).joined(separator: "\n\n")
    }

    private mutating func renderAppSpecificExtensionBundle(
        _ target: TuistTarget,
        packagePath: String,
        consumer: AppSpecificExtensionConsumer
    ) throws -> String {
        let wrapper = appSpecificExtensionTarget(from: target, consumer: consumer)
        switch target.product {
        case .appExtension, .extensionKitExtension:
            let deps = try resolvedDependencies(for: target, packagePath: packagePath)
            let platform = platform(for: target)
            let ruleName: String
            switch platform {
            case .ios:
                ruleName = "ios_extension"
            case .macOS:
                ruleName = "macos_extension"
            case .tvOS:
                ruleName = "tvos_extension"
            case .watchOS:
                ruleName = "watchos_extension"
            }
            return renderExtensionBundleRule(
                target,
                packagePath: packagePath,
                deps: deps,
                platform: platform,
                ruleName: ruleName,
                name: consumer.wrapperName,
                bundleId: consumer.bundleId,
                infoPlistTarget: wrapper,
                extraAttributes: extensionExtraAttributes(for: target, platform: platform)
            )
        case .messagesExtension:
            let deps = try resolvedDependencies(for: target, packagePath: packagePath)
            return renderExtensionBundleRule(
                target,
                packagePath: packagePath,
                deps: deps,
                platform: .ios,
                ruleName: "ios_imessage_extension",
                name: consumer.wrapperName,
                bundleId: consumer.bundleId,
                infoPlistTarget: wrapper
            )
        case .stickerPackExtension:
            return try renderStickerPackExtensionBundle(
                target,
                packagePath: packagePath,
                name: consumer.wrapperName,
                bundleId: consumer.bundleId,
                infoPlistTarget: wrapper
            )
        case .tvTopShelfExtension:
            return try renderTVTopShelfExtensionBundle(
                target,
                packagePath: packagePath,
                name: consumer.wrapperName,
                bundleId: consumer.bundleId,
                infoPlistTarget: wrapper
            )
        case .app, .framework, .staticFramework, .staticLibrary, .dynamicLibrary, .macro, .bundle, .unitTests, .uiTests, .unsupported:
            return ""
        }
    }

    private func appSpecificExtensionTarget(
        from target: TuistTarget,
        consumer: AppSpecificExtensionConsumer
    ) -> TuistTarget {
        TuistTarget(
            name: consumer.wrapperName,
            product: target.product,
            bundleId: consumer.bundleId,
            productName: target.productName,
            projectPath: target.projectPath,
            infoPlistPath: target.infoPlistPath,
            infoPlistEntries: target.infoPlistEntries,
            sources: target.sources,
            headers: target.headers,
            resources: target.resources,
            dependencies: target.dependencies
        )
    }

    private func extensionExtraAttributes(for target: TuistTarget, platform: ApplePlatform) -> String {
        var attributes = ""
        if target.product == .extensionKitExtension {
            attributes += "    extensionkit_extension = True,\n"
        }
        if platform == .watchOS && target.product == .appExtension {
            attributes += "    application_extension = True,\n"
        }
        return attributes
    }

    private mutating func renderStickerPackExtensionBundle(
        _ target: TuistTarget,
        packagePath: String,
        name: String,
        bundleId: String,
        infoPlistTarget: TuistTarget
    ) throws -> String {
        let resources = try resourceExpressions(for: target, packagePath: packagePath)
        let resourceExpressions = resources.resources + resources.structuredResources
        return [
            try renderBundleImportsIfNeeded(target, packagePath: packagePath),
            """
            ios_sticker_pack_extension(
                name = "\(name)",
                bundle_id = "\(bundleId)",
                families = ["iphone", "ipad"],
            \(infoplistsAttribute(infoPlistTarget, packagePath: packagePath, indent: 4))    minimum_os_version = "17.0",
                resources = \(Starlark.exprList(resourceExpressions, indent: 4)),
            )
            """
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n\n")
    }

    private mutating func renderStickerPackExtension(_ target: TuistTarget, packagePath: String) throws -> String {
        try renderStickerPackExtensionBundle(
            target,
            packagePath: packagePath,
            name: target.name,
            bundleId: target.bundleId ?? defaultBundleId(for: target),
            infoPlistTarget: target
        )
    }

    private mutating func renderTVTopShelfExtension(_ target: TuistTarget, packagePath: String) throws -> String {
        try renderTVTopShelfExtensionBundle(
            target,
            packagePath: packagePath,
            name: target.name,
            bundleId: target.bundleId ?? defaultBundleId(for: target),
            infoPlistTarget: target
        )
    }

    private mutating func renderTVTopShelfExtensionBundle(
        _ target: TuistTarget,
        packagePath: String,
        name: String,
        bundleId: String,
        infoPlistTarget: TuistTarget
    ) throws -> String {
        let deps = try resolvedDependencies(for: target, packagePath: packagePath)
        return [
            try renderResourceGroupIfNeeded(target, packagePath: packagePath),
            try renderSwiftLibrary(target, packagePath: packagePath, name: libraryName(for: target), testonly: false, manual: true, resolved: deps),
            """
            tvos_extension(
                name = "\(name)",
                bundle_id = "\(bundleId)",
                families = ["tv"],
            \(infoplistsAttribute(infoPlistTarget, packagePath: packagePath, indent: 4))    minimum_os_version = "17.0",
                deps = [":\(libraryName(for: target))"],
            \(optionalLabelListAttribute("frameworks", deps.frameworkDeps, packagePath: packagePath, indent: 4))\(optionalLabelListAttribute("resources", deps.resourceDeps + resourceGroupLabelIfNeeded(target, packagePath: packagePath), packagePath: packagePath, indent: 4)))
            """
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n\n")
            .replacingOccurrences(of: ")\n \n", with: ")\n")
    }

    private mutating func renderFramework(_ target: TuistTarget, packagePath: String) throws -> String {
        switch platform(for: target) {
        case .ios:
            return try renderIOSFramework(target, packagePath: packagePath)
        case .macOS:
            return try renderMacOSFramework(target, packagePath: packagePath)
        case .tvOS:
            return try renderTVOSFramework(target, packagePath: packagePath)
        case .watchOS:
            return try renderWatchOSFramework(target, packagePath: packagePath)
        }
    }

    private mutating func renderIOSFramework(_ target: TuistTarget, packagePath: String) throws -> String {
        let deps = try resolvedDependencies(for: target, packagePath: packagePath)
        let platform = ApplePlatform.ios
        let libraryBlock = try frameworkLibraryBlockIfNeeded(target, packagePath: packagePath, deps: deps)
        let productDeps = hasSwiftLibrary(for: target) ? "    deps = [\":\(libraryName(for: target))\"],\n" : ""
        return [
            try renderResourceGroupIfNeeded(target, packagePath: packagePath),
            libraryBlock,
            """
            ios_framework(
                name = "\(target.name)",
            \(bundleNameAttribute(target, indent: 4))    bundle_id = "\(target.bundleId ?? defaultBundleId(for: target))",
                families = ["iphone", "ipad"],
            \(extensionSafeAttribute(target, indent: 4))\(infoplistsAttribute(target, packagePath: packagePath, indent: 4))    minimum_os_version = "\(minimumOSVersion(for: platform))",
            \(productDeps)\(optionalLabelListAttribute("frameworks", deps.frameworkDeps, packagePath: packagePath, indent: 4))
            \(optionalLabelListAttribute("resources", deps.resourceDeps + resourceGroupLabelIfNeeded(target, packagePath: packagePath), packagePath: packagePath, indent: 4)))
            """
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n\n")
            .replacingOccurrences(of: ")\n \n", with: ")\n")
    }

    private mutating func renderMacOSFramework(_ target: TuistTarget, packagePath: String) throws -> String {
        let deps = try resolvedDependencies(for: target, packagePath: packagePath)
        let platform = ApplePlatform.macOS
        let libraryBlock = try frameworkLibraryBlockIfNeeded(target, packagePath: packagePath, deps: deps)
        let productDeps = hasSwiftLibrary(for: target) ? "    deps = [\":\(libraryName(for: target))\"],\n" : ""
        return [
            try renderResourceGroupIfNeeded(target, packagePath: packagePath),
            libraryBlock,
            """
            macos_framework(
                name = "\(target.name)",
            \(bundleNameAttribute(target, indent: 4))    bundle_id = "\(target.bundleId ?? defaultBundleId(for: target))",
            \(extensionSafeAttribute(target, indent: 4))\(infoplistsAttribute(target, packagePath: packagePath, indent: 4))    minimum_os_version = "\(minimumOSVersion(for: platform))",
            \(productDeps)\(optionalLabelListAttribute("frameworks", deps.frameworkDeps, packagePath: packagePath, indent: 4))
            \(optionalLabelListAttribute("resources", deps.resourceDeps + resourceGroupLabelIfNeeded(target, packagePath: packagePath), packagePath: packagePath, indent: 4)))
            """
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n\n")
            .replacingOccurrences(of: ")\n \n", with: ")\n")
    }

    private mutating func renderTVOSFramework(_ target: TuistTarget, packagePath: String) throws -> String {
        let deps = try resolvedDependencies(for: target, packagePath: packagePath)
        let platform = ApplePlatform.tvOS
        let libraryBlock = try frameworkLibraryBlockIfNeeded(target, packagePath: packagePath, deps: deps)
        let productDeps = hasSwiftLibrary(for: target) ? "    deps = [\":\(libraryName(for: target))\"],\n" : ""
        return [
            try renderResourceGroupIfNeeded(target, packagePath: packagePath),
            libraryBlock,
            """
            tvos_framework(
                name = "\(target.name)",
            \(bundleNameAttribute(target, indent: 4))    bundle_id = "\(target.bundleId ?? defaultBundleId(for: target))",
                families = ["tv"],
            \(extensionSafeAttribute(target, indent: 4))\(infoplistsAttribute(target, packagePath: packagePath, indent: 4))    minimum_os_version = "\(minimumOSVersion(for: platform))",
            \(productDeps)\(optionalLabelListAttribute("frameworks", deps.frameworkDeps, packagePath: packagePath, indent: 4))
            \(optionalLabelListAttribute("resources", deps.resourceDeps + resourceGroupLabelIfNeeded(target, packagePath: packagePath), packagePath: packagePath, indent: 4)))
            """
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n\n")
            .replacingOccurrences(of: ")\n \n", with: ")\n")
    }

    private mutating func renderWatchOSFramework(_ target: TuistTarget, packagePath: String) throws -> String {
        let deps = try resolvedDependencies(for: target, packagePath: packagePath)
        let platform = ApplePlatform.watchOS
        let libraryBlock = try frameworkLibraryBlockIfNeeded(target, packagePath: packagePath, deps: deps)
        let productDeps = hasSwiftLibrary(for: target) ? "    deps = [\":\(libraryName(for: target))\"],\n" : ""
        return [
            try renderResourceGroupIfNeeded(target, packagePath: packagePath),
            libraryBlock,
            """
            watchos_framework(
                name = "\(target.name)",
            \(bundleNameAttribute(target, indent: 4))    bundle_id = "\(target.bundleId ?? defaultBundleId(for: target))",
            \(extensionSafeAttribute(target, indent: 4))\(infoplistsAttribute(target, packagePath: packagePath, indent: 4))    minimum_os_version = "\(minimumOSVersion(for: platform))",
            \(productDeps)\(optionalLabelListAttribute("frameworks", deps.frameworkDeps, packagePath: packagePath, indent: 4))
            \(optionalLabelListAttribute("resources", deps.resourceDeps + resourceGroupLabelIfNeeded(target, packagePath: packagePath), packagePath: packagePath, indent: 4)))
            """
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n\n")
            .replacingOccurrences(of: ")\n \n", with: ")\n")
    }

    private mutating func frameworkLibraryBlockIfNeeded(
        _ target: TuistTarget,
        packagePath: String,
        deps: ResolvedDependencies
    ) throws -> String? {
        guard hasSwiftLibrary(for: target) else {
            return nil
        }
        return try renderSwiftLibrary(target, packagePath: packagePath, name: libraryName(for: target), testonly: false, manual: true, resolved: deps)
    }

    private func extensionSafeAttribute(_ target: TuistTarget, indent: Int) -> String {
        guard extensionSafeTargets.contains(targetIdentity(target)) else {
            return ""
        }
        return "\(String(repeating: " ", count: indent))extension_safe = True,\n"
    }

    private func bundleNameAttribute(_ target: TuistTarget, indent: Int) -> String {
        guard target.productName != target.name else {
            return ""
        }
        return "\(String(repeating: " ", count: indent))bundle_name = \"\(target.productName)\",\n"
    }

    private func familiesAttribute(for platform: ApplePlatform, indent: Int) -> String {
        let prefix = String(repeating: " ", count: indent)
        switch platform {
        case .ios:
            return "\(prefix)families = [\"iphone\", \"ipad\"],\n"
        case .tvOS:
            return "\(prefix)families = [\"tv\"],\n"
        case .watchOS:
            return "\(prefix)families = [\"watch\"],\n"
        case .macOS:
            return ""
        }
    }

    private mutating func renderStaticFramework(_ target: TuistTarget, packagePath: String) throws -> String {
        let deps = try resolvedDependencies(for: target, packagePath: packagePath)
        var parts: [String] = []
        if let resources = try renderResourceGroupIfNeeded(target, packagePath: packagePath) {
            parts.append(resources)
        }
        if !hasSwiftLibrary(for: target) {
            warnings.append("static framework \(target.name) has no sources; generated its resources but skipped an ios_static_framework wrapper")
            if parts.isEmpty {
                parts.append("# \(target.name) skipped: source-less static framework")
            }
            return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n\n")
        }
        parts.append(try renderSwiftLibrary(target, packagePath: packagePath, name: libraryName(for: target), testonly: false, manual: true, resolved: deps))

        let frameworkDeps = [BazelLabel(package: packagePath, name: libraryName(for: target))]
        parts.append(
            """
            ios_static_framework(
                name = "\(target.name)",
                minimum_os_version = "17.0",
            \(optionalLabelListAttribute("avoid_deps", deps.codeDeps, packagePath: packagePath, indent: 4))\(optionalLabelListAttribute("deps", frameworkDeps, packagePath: packagePath, indent: 4))\(optionalLabelListAttribute("resources", deps.resourceDeps + resourceGroupLabelIfNeeded(target, packagePath: packagePath), packagePath: packagePath, indent: 4)))
            """
        )
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n\n")
            .replacingOccurrences(of: ")\n \n", with: ")\n")
    }

    private mutating func renderLibrary(_ target: TuistTarget, packagePath: String) throws -> String {
        let deps = try resolvedDependencies(for: target, packagePath: packagePath)
        return [
            try renderResourceGroupIfNeeded(target, packagePath: packagePath),
            try renderSwiftLibrary(target, packagePath: packagePath, name: target.name, testonly: false, manual: true, resolved: deps),
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n\n")
    }

    private mutating func renderUnitTest(_ target: TuistTarget, packagePath: String) throws -> String {
        let deps = try resolvedDependencies(for: target, packagePath: packagePath)
        let platform = platform(for: target)
        let ruleName: String
        switch platform {
        case .ios:
            ruleName = "ios_unit_test"
        case .macOS:
            ruleName = "macos_unit_test"
        case .tvOS:
            ruleName = "tvos_unit_test"
        case .watchOS:
            ruleName = "watchos_unit_test"
        }
        var lines = [
            "\(ruleName)(",
            "    name = \"\(target.name)\",",
            "    bundle_id = \"\(target.bundleId ?? defaultBundleId(for: target))\",",
        ]
        if let infoPlistPath = target.infoPlistPath,
           let relative = try? paths.pathRelativeToPackage(infoPlistPath, packagePath: packagePath) {
            lines.append("    infoplists = [\(Starlark.quote(relative))],")
        }
        lines.append("    minimum_os_version = \"\(minimumOSVersion(for: platform))\",")
        lines.append("    deps = [\":\(libraryName(for: target))\"],")
        if let testHost = deps.testHost {
            lines.append("    test_host = \"\(testHost.localDescription(in: packagePath))\",")
            lines.append("    test_host_is_bundle_loader = True,")
        }
        lines.append(")")

        return [
            try renderResourceGroupIfNeeded(target, packagePath: packagePath),
            try renderSwiftLibrary(target, packagePath: packagePath, name: libraryName(for: target), testonly: true, manual: true, resolved: deps),
            lines.joined(separator: "\n"),
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n\n")
    }

    private mutating func renderCompilerPlugin(_ target: TuistTarget, packagePath: String) throws -> String {
        let deps = try resolvedDependencies(for: target, packagePath: packagePath)
        let srcs = try sourceLabels(for: target, packagePath: packagePath)
        let tagsAttribute = "    tags = [\"manual\"],\n"
        let pluginsAttribute = deps.pluginDeps.isEmpty ? "" : "    plugins = \(Starlark.list(deps.pluginDeps.map { $0.localDescription(in: packagePath) }, indent: 4)),\n"

        return """
        swift_compiler_plugin(
            name = "\(target.name)",
            srcs = \(Starlark.list(srcs, indent: 4)),
            module_name = "\(sanitizedModuleName(target.productName))",
        \(pluginsAttribute)\(tagsAttribute)    deps = \(Starlark.list(deps.codeDeps.map { $0.localDescription(in: packagePath) }, indent: 4)),
        )
        """
    }

    private mutating func renderResourceBundle(_ target: TuistTarget, packagePath: String) throws -> String {
        let resources = try resourceExpressions(for: target, packagePath: packagePath)
        return [
            try renderBundleImportsIfNeeded(target, packagePath: packagePath),
            """
        apple_resource_bundle(
            name = "\(target.name)",
            bundle_id = "\(target.bundleId ?? defaultBundleId(for: target))",
        \(infoplistsAttribute(target, packagePath: packagePath, indent: 4))    resources = \(Starlark.exprList(resources.resources, indent: 4)),
            structured_resources = \(Starlark.exprList(resources.structuredResources, indent: 4)),
        )
        """,
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n\n")
    }

    private mutating func renderSwiftLibrary(
        _ target: TuistTarget,
        packagePath: String,
        name: String,
        testonly: Bool,
        manual: Bool = false,
        resolved deps: ResolvedDependencies
    ) throws -> String {
        try renderSwiftLibrary(
            target,
            packagePath: packagePath,
            name: name,
            testonly: testonly,
            manual: manual,
            extraDeps: deps.codeDeps,
            pluginDeps: deps.pluginDeps,
            sdkFrameworks: deps.sdkFrameworks,
            weakSdkFrameworks: deps.weakSdkFrameworks,
            sdkDylibs: deps.sdkDylibs,
            linkopts: deps.linkopts,
            includeDeveloperSearchPaths: deps.includeDeveloperSearchPaths
        )
    }

    private mutating func renderSwiftLibrary(
        _ target: TuistTarget,
        packagePath: String,
        name: String,
        testonly: Bool,
        manual: Bool = false,
        extraDeps: [BazelLabel] = [],
        pluginDeps: [BazelLabel] = [],
        sdkFrameworks: [String] = [],
        weakSdkFrameworks: [String] = [],
        sdkDylibs: [String] = [],
        linkopts: [String] = [],
        includeDeveloperSearchPaths: Bool = false
    ) throws -> String {
        let srcs = try sourceLabels(for: target, packagePath: packagePath)
        var clangSrcs = try clangSourceLabels(for: target, packagePath: packagePath)
        let headers = try headerLabels(for: target, packagePath: packagePath)
        let deps = extraDeps
        let data = resourceGroupLabelIfNeeded(target, packagePath: packagePath)
        let testableCopts = targetsWithTestConsumers.contains(target.name) || testonly ? ["-enable-testing"] : []
        let developerSearchPath = testonly || includeDeveloperSearchPaths ? "    always_include_developer_search_paths = True,\n" : ""
        let testonlyAttribute = testonly ? "    testonly = True,\n" : ""
        let tagsAttribute = manual ? "    tags = [\"manual\"],\n" : ""
        let coptsAttribute = testableCopts.isEmpty ? "" : "    copts = \(Starlark.list(testableCopts, indent: 4)),\n"
        let dataAttribute = data.isEmpty ? "" : "    data = \(Starlark.list(data.map { $0.localDescription(in: packagePath) }, indent: 4)),\n"
        let linkoptsAttribute = linkopts.isEmpty ? "" : "    linkopts = \(Starlark.orderedList(linkopts, indent: 4)),\n"
        let plugins = pluginDeps.map { $0.localDescription(in: packagePath) }
        let pluginsAttribute = plugins.isEmpty ? "" : "    plugins = \(Starlark.list(plugins, indent: 4)),\n"
        let swiftPluginsAttribute = plugins.isEmpty ? "" : "    swift_plugins = \(Starlark.list(plugins, indent: 4)),\n"

        if clangSrcs.isEmpty, requiresObjCLibrary(target), target.sources.contains(where: isClangSource) {
            clangSrcs.append(generatedObjCStubSource(for: target, packagePath: packagePath))
        }

        if !clangSrcs.isEmpty || !headers.isEmpty {
            let umbrella = umbrellaHeader(for: target, headers: headers)
            let hdrs = umbrella.map { umbrella in headers.filter { $0 != umbrella } } ?? headers
            let includes = includeDirectories(for: headers)
            let includesAttribute = includes.isEmpty ? "" : "    includes = \(Starlark.list(includes, indent: 4)),\n"
            let sdkFrameworksAttribute = sdkFrameworks.isEmpty ? "" : "    sdk_frameworks = \(Starlark.list(sdkFrameworks, indent: 4)),\n"
            let weakSdkFrameworksAttribute = weakSdkFrameworks.isEmpty ? "" : "    weak_sdk_frameworks = \(Starlark.list(weakSdkFrameworks, indent: 4)),\n"
            let sdkDylibsAttribute = sdkDylibs.isEmpty ? "" : "    sdk_dylibs = \(Starlark.list(sdkDylibs, indent: 4)),\n"
            let swiftCoptsAttribute = testableCopts.isEmpty ? "" : "    swift_copts = \(Starlark.list(testableCopts, indent: 4)),\n"

            if srcs.isEmpty {
                return """
                objc_library(
                    name = "\(name)",
                    srcs = \(Starlark.list(clangSrcs, indent: 4)),
                    hdrs = \(Starlark.list(hdrs, indent: 4)),
                \(dataAttribute)    enable_modules = True,
                \(includesAttribute)\(linkoptsAttribute)    module_name = "\(sanitizedModuleName(target.productName))",
                \(sdkDylibsAttribute)\(sdkFrameworksAttribute)\(tagsAttribute)\(testonlyAttribute)\(weakSdkFrameworksAttribute)    deps = \(Starlark.list(deps.map { $0.localDescription(in: packagePath) }, indent: 4)),
                )
                """
            }

            return """
            mixed_language_library(
                name = "\(name)",
                clang_srcs = \(Starlark.list(clangSrcs, indent: 4)),
                hdrs = \(Starlark.list(hdrs, indent: 4)),
            \(developerSearchPath)\(dataAttribute)    enable_modules = True,
            \(includesAttribute)\(linkoptsAttribute)    module_name = "\(sanitizedModuleName(target.productName))",
            \(sdkDylibsAttribute)\(sdkFrameworksAttribute)\(swiftCoptsAttribute)\(swiftPluginsAttribute)    swift_srcs = \(Starlark.list(srcs, indent: 4)),
            \(tagsAttribute)\(testonlyAttribute)\(weakSdkFrameworksAttribute)    deps = \(Starlark.list(deps.map { $0.localDescription(in: packagePath) }, indent: 4)),
            )
            """
        }

        return """
        swift_library(
            name = "\(name)",
            srcs = \(Starlark.list(srcs, indent: 4)),
        \(developerSearchPath)\(coptsAttribute)\(dataAttribute)\(linkoptsAttribute)    module_name = "\(sanitizedModuleName(target.productName))",
        \(pluginsAttribute)\(tagsAttribute)\(testonlyAttribute)    deps = \(Starlark.list(deps.map { $0.localDescription(in: packagePath) }, indent: 4)),
        )
        """
    }

    private mutating func renderResourceGroupIfNeeded(_ target: TuistTarget, packagePath: String) throws -> String? {
        guard !target.resources.isEmpty, target.product != .bundle else { return nil }
        let resources = try resourceExpressions(for: target, packagePath: packagePath)
        return [
            try renderBundleImportsIfNeeded(target, packagePath: packagePath),
            """
        apple_resource_group(
            name = "_\(target.name)Resources",
            resources = \(Starlark.exprList(resources.resources, indent: 4)),
            structured_resources = \(Starlark.exprList(resources.structuredResources, indent: 4)),
        )
        """,
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n\n")
    }

    private mutating func sourceLabels(for target: TuistTarget, packagePath: String) throws -> [String] {
        var sources = try target.sources.filter { $0.hasSuffix(".swift") }.map {
            try paths.pathRelativeToPackage($0, packagePath: packagePath)
        }
        if let generatedAccessor = try generatedResourceAccessorSource(for: target, packagePath: packagePath) {
            sources.append(generatedAccessor)
        }
        return sources
    }

    private mutating func generatedObjCStubSource(for target: TuistTarget, packagePath: String) -> String {
        let relative = ".bazel/Generated/\(sanitizedModuleName(target.name))ObjCStub.m"
        let generatedOutputPath = packagePath.isEmpty ? relative : "\(packagePath)/\(relative)"
        if generatedFiles[generatedOutputPath] == nil {
            generatedFiles[generatedOutputPath] = "void _\(sanitizedModuleName(target.name))BazelObjCStub(void) {}\n"
            warnings.append("generated Objective-C stub for \(target.name) at \(generatedOutputPath)")
        }
        return relative
    }

    private func requiresMixedLanguage(_ target: TuistTarget) -> Bool {
        hasRenderableObjCInputs(target) && hasSwiftInputs(target)
    }

    private func requiresObjCLibrary(_ target: TuistTarget) -> Bool {
        requiresObjCInterop(target) && !hasSwiftInputs(target)
    }

    private func requiresObjCInterop(_ target: TuistTarget) -> Bool {
        target.sources.contains(where: isClangSource) || !target.headers.all.isEmpty
    }

    private func hasRenderableObjCInputs(_ target: TuistTarget) -> Bool {
        target.sources.contains { isClangSource($0) && !isAutoLinkingStubFile($0) }
            || target.headers.all.contains { !isAutoLinkingStubFile($0) }
    }

    private func hasSwiftInputs(_ target: TuistTarget) -> Bool {
        target.sources.contains { $0.hasSuffix(".swift") }
            || resourceAccessors.shouldGenerate(for: target)
    }

    private func isClangSource(_ path: String) -> Bool {
        let supportedExtensions = ["c", "cc", "cpp", "cxx", "m", "mm"]
        return supportedExtensions.contains(URL(fileURLWithPath: path).pathExtension)
    }

    private func clangSourceLabels(for target: TuistTarget, packagePath: String) throws -> [String] {
        try target.sources.filter { isClangSource($0) && !isAutoLinkingStubFile($0) }.map {
            try paths.pathRelativeToPackage($0, packagePath: packagePath)
        }
    }

    private func isAutoLinkingStubFile(_ path: String) -> Bool {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return false
        }

        let withoutBlockComments = replacingMatches(
            pattern: #"/\*.*?\*/"#,
            in: content,
            options: [.dotMatchesLineSeparators],
            with: ""
        )
        let code = withoutBlockComments
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                line.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return firstMatch(pattern: #"^@import\s+[A-Za-z_][A-Za-z0-9_]*\s*;$"#, in: code) != nil
    }

    private func headerLabels(for target: TuistTarget, packagePath: String) throws -> [String] {
        try target.headers.all.filter { !isAutoLinkingStubFile($0) }.map {
            try paths.pathRelativeToPackage($0, packagePath: packagePath)
        }
    }

    private func umbrellaHeader(for target: TuistTarget, headers: [String]) -> String? {
        let candidates = ["\(target.productName).h", "\(target.name).h"]
        return headers.first { candidates.contains(URL(fileURLWithPath: $0).lastPathComponent) }
    }

    private func includeDirectories(for headers: [String]) -> [String] {
        Array(Set(headers.map { ($0 as NSString).deletingLastPathComponent })).sorted()
    }

    private mutating func resourceExpressions(for target: TuistTarget, packagePath: String) throws -> (resources: [String], structuredResources: [String]) {
        var resources: Set<String> = []
        var structured: Set<String> = []

        for resource in target.resources {
            let relative = try paths.pathRelativeToPackage(resource.path, packagePath: packagePath)
            if !resource.tags.isEmpty {
                let tags = resource.tags.joined(separator: ", ")
                warnings.append("target \(target.name) has ODR tags \(tags) on \(relative); tags are not represented in generated Bazel files")
            }

            switch resource.kind {
            case .folderReference:
                structured.insert(globExpression(relative))
            case .file:
                if isDirectory(resource.path), URL(fileURLWithPath: resource.path).pathExtension == "bundle" {
                    resources.insert(Starlark.quote(":\(bundleImportName(target: target, relativePath: relative))"))
                    continue
                }
                if isDirectory(resource.path) {
                    resources.insert(globExpression(relative))
                } else {
                    resources.insert(Starlark.quote(relative))
                }
            }
        }

        return (Array(resources), Array(structured))
    }

    private func globExpression(_ relativePath: String) -> String {
        "glob([\(Starlark.quote(relativePath + "/**"))])"
    }

    private func renderBundleImportsIfNeeded(_ target: TuistTarget, packagePath: String) throws -> String? {
        let imports = try target.resources.compactMap { resource -> String? in
            guard resource.kind == .file,
                  isDirectory(resource.path),
                  URL(fileURLWithPath: resource.path).pathExtension == "bundle" else {
                return nil
            }
            let relative = try paths.pathRelativeToPackage(resource.path, packagePath: packagePath)
            return """
            apple_bundle_import(
                name = "\(bundleImportName(target: target, relativePath: relative))",
                bundle_imports = glob([\(Starlark.quote(relative + "/**"))]),
            )
            """
        }

        guard !imports.isEmpty else { return nil }
        return imports.joined(separator: "\n\n")
    }

    private func bundleImportName(target: TuistTarget, relativePath: String) -> String {
        "_\(target.name)_\(sanitizedModuleName(relativePath))"
    }

    private func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func resourceGroupLabelIfNeeded(_ target: TuistTarget, packagePath: String) -> [BazelLabel] {
        target.resources.isEmpty || target.product == .bundle ? [] : [BazelLabel(package: packagePath, name: "_\(target.name)Resources")]
    }

    private func libraryName(for target: TuistTarget) -> String {
        switch target.product {
        case .app, .appExtension, .extensionKitExtension, .framework, .messagesExtension, .staticFramework, .tvTopShelfExtension, .unitTests, .uiTests:
            "\(target.name)Lib"
        case .staticLibrary, .dynamicLibrary, .macro, .bundle, .stickerPackExtension, .unsupported:
            target.name
        }
    }

    private func productLabel(for target: TuistTarget) throws -> BazelLabel {
        BazelLabel(package: try paths.packagePath(for: target.projectPath), name: target.name)
    }

    private func hasSwiftLibrary(for target: TuistTarget) -> Bool {
        target.product.isSwiftBacked && (
            target.sources.contains { $0.hasSuffix(".swift") } ||
            target.sources.contains(where: isClangSource) ||
            !target.headers.all.isEmpty ||
            resourceAccessors.shouldGenerate(for: target)
        )
    }

    private func libraryLabel(for target: TuistTarget) throws -> BazelLabel? {
        guard hasSwiftLibrary(for: target) else { return nil }
        return BazelLabel(package: try paths.packagePath(for: target.projectPath), name: libraryName(for: target))
    }

    private func resourceLabel(for target: TuistTarget) throws -> BazelLabel? {
        if target.product == .bundle {
            return try productLabel(for: target)
        }
        guard !target.resources.isEmpty else { return nil }
        return BazelLabel(package: try paths.packagePath(for: target.projectPath), name: "_\(target.name)Resources")
    }

    private mutating func infoplistsAttribute(_ target: TuistTarget, packagePath: String, indent: Int) -> String {
        guard let relative = infoPlistRelativePath(target, packagePath: packagePath) else {
            return ""
        }
        return "\(String(repeating: " ", count: indent))infoplists = [\(Starlark.quote(relative))],\n"
    }

    private mutating func infoPlistRelativePath(_ target: TuistTarget, packagePath: String) -> String? {
        guard let infoPlistPath = target.infoPlistPath,
              let originalRelative = try? paths.pathRelativeToPackage(infoPlistPath, packagePath: packagePath) else {
            return generatedDefaultInfoPlistRelativePath(for: target, packagePath: packagePath)
        }

        guard let original = try? String(contentsOfFile: infoPlistPath, encoding: .utf8) else {
            return originalRelative
        }

        let sanitized = substitutionMap(for: target).reduce(original) { content, replacement in
            content.replacingOccurrences(of: replacement.key, with: replacement.value)
        }
        guard sanitized != original else {
            return originalRelative
        }

        let generatedRelative = ".bazel/InfoPlists/\(target.name)-Info.plist"
        let generatedOutputPath = packagePath.isEmpty ? generatedRelative : "\(packagePath)/\(generatedRelative)"
        generatedFiles[generatedOutputPath] = sanitized
        warnings.append("generated sanitized Info.plist for \(target.name) at \(generatedOutputPath)")
        return generatedRelative
    }

    private mutating func generatedDefaultInfoPlistRelativePath(for target: TuistTarget, packagePath: String) -> String? {
        guard supportsGeneratedDefaultInfoPlist(target.product) else {
            return nil
        }

        let generatedRelative = ".bazel/InfoPlists/\(target.name)-Info.plist"
        let generatedOutputPath = packagePath.isEmpty ? generatedRelative : "\(packagePath)/\(generatedRelative)"
        if generatedFiles[generatedOutputPath] == nil {
            let dictionary = defaultInfoPlistDictionary(for: target)
            guard let data = try? PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0),
                  let content = String(data: data, encoding: .utf8) else {
                warnings.append("failed to generate default Info.plist for \(target.name)")
                return nil
            }
            generatedFiles[generatedOutputPath] = content
            warnings.append("generated default Info.plist for \(target.name) at \(generatedOutputPath)")
        }
        return generatedRelative
    }

    private func supportsGeneratedDefaultInfoPlist(_ product: ProductType) -> Bool {
        switch product {
        case .app, .appExtension, .extensionKitExtension, .framework, .messagesExtension, .stickerPackExtension, .tvTopShelfExtension:
            true
        case .staticFramework, .staticLibrary, .dynamicLibrary, .macro, .bundle, .unitTests, .uiTests, .unsupported:
            false
        }
    }

    private func defaultInfoPlistDictionary(for target: TuistTarget) -> [String: Any] {
        var dictionary: [String: Any] = [
            "CFBundleDevelopmentRegion": "en",
            "CFBundleExecutable": target.productName,
            "CFBundleIdentifier": target.bundleId ?? defaultBundleId(for: target),
            "CFBundleName": target.productName,
            "CFBundlePackageType": packageType(for: target.product),
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1.0",
        ]
        let substitutions = substitutionMap(for: target)
        for (key, value) in target.infoPlistEntries {
            dictionary[key] = propertyListObject(for: value, substitutions: substitutions)
        }
        if let host = extensionHostApp(for: target) {
            let hostVersions = versionInfoPlistValues(for: host)
            if target.infoPlistEntries["CFBundleVersion"] == nil {
                dictionary["CFBundleVersion"] = hostVersions.bundleVersion
            }
            if target.infoPlistEntries["CFBundleShortVersionString"] == nil {
                dictionary["CFBundleShortVersionString"] = hostVersions.shortVersion
            }
        }
        return dictionary
    }

    private func versionInfoPlistValues(for target: TuistTarget) -> (bundleVersion: Any, shortVersion: Any) {
        let substitutions = substitutionMap(for: target)
        let bundleVersion = target.infoPlistEntries["CFBundleVersion"].map {
            propertyListObject(for: $0, substitutions: substitutions)
        } ?? "1.0"
        let shortVersion = target.infoPlistEntries["CFBundleShortVersionString"].map {
            propertyListObject(for: $0, substitutions: substitutions)
        } ?? "1.0"
        return (bundleVersion, shortVersion)
    }

    private func extensionHostApp(for target: TuistTarget) -> TuistTarget? {
        guard isExtensionProduct(target.product) else {
            return nil
        }
        let identity = targetIdentity(target)
        return graph.projects.flatMap(\.targets)
            .filter { $0.product == .app }
            .sorted { $0.name < $1.name }
            .first { app in
                app.dependencies.contains { dependency in
                    resolveTargetDependency(dependency).map(targetIdentity) == identity
                }
            }
    }

    private func packageType(for product: ProductType) -> String {
        switch product {
        case .app:
            "APPL"
        case .framework:
            "FMWK"
        default:
            "XPC!"
        }
    }

    private func propertyListObject(for value: PlistValue, substitutions: [String: String]) -> Any {
        switch value {
        case let .string(string):
            substitutions.reduce(string) { content, replacement in
                content.replacingOccurrences(of: replacement.key, with: replacement.value)
            }
        case let .bool(bool):
            bool
        case let .number(number):
            number.rounded() == number ? Int(number) : number
        case let .array(values):
            values.map { propertyListObject(for: $0, substitutions: substitutions) }
        case let .dictionary(values):
            values.reduce(into: [String: Any]()) { result, element in
                result[element.key] = propertyListObject(for: element.value, substitutions: substitutions)
            }
        }
    }

    private func substitutionMap(for target: TuistTarget) -> [String: String] {
        [
            "$(CURRENT_PROJECT_VERSION)": "1.0",
            "$(MARKETING_VERSION)": "1.0",
            "$(DEVELOPMENT_LANGUAGE)": "en",
            "$(EXECUTABLE_NAME)": target.productName,
            "$(PRODUCT_BUNDLE_IDENTIFIER)": target.bundleId ?? defaultBundleId(for: target),
            "$(PRODUCT_MODULE_NAME)": sanitizedModuleName(target.productName),
            "$(PRODUCT_NAME)": target.productName,
            "$(TARGET_NAME)": target.name,
        ]
    }

    private mutating func generatedResourceAccessorSource(for target: TuistTarget, packagePath: String) throws -> String? {
        guard resourceAccessors.shouldGenerate(for: target) else {
            return nil
        }

        let relative = resourceAccessors.relativePath(for: target)
        let generatedOutputPath = packagePath.isEmpty ? relative : "\(packagePath)/\(relative)"
        if generatedFiles[generatedOutputPath] == nil {
            generatedFiles[generatedOutputPath] = resourceAccessors.render(for: target)
            warnings.append("generated synthesized resource accessors for \(target.name) at \(generatedOutputPath)")
        }
        return relative
    }

    private func optionalLabelListAttribute(_ name: String, _ labels: [BazelLabel], packagePath: String, indent: Int) -> String {
        guard !labels.isEmpty else { return "" }
        let values = labels.sorted().map { $0.localDescription(in: packagePath) }
        return "\(String(repeating: " ", count: indent))\(name) = \(Starlark.list(values, indent: indent)),\n"
    }

    private func optionalLabelAttribute(_ name: String, _ label: BazelLabel?, packagePath: String, indent: Int) -> String {
        guard let label else { return "" }
        return "\(String(repeating: " ", count: indent))\(name) = \"\(label.localDescription(in: packagePath))\",\n"
    }

    private func defaultBundleId(for target: TuistTarget) -> String {
        "dev.tuist.\(sanitizedModuleName(target.name))"
    }

    private struct ResolvedDependencies {
        var codeDeps: [BazelLabel] = []
        var pluginDeps: [BazelLabel] = []
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

    private struct AppSpecificExtensionConsumer {
        let wrapperName: String
        let bundleId: String
    }

    private mutating func resolvedDependencies(for target: TuistTarget, packagePath: String) throws -> ResolvedDependencies {
        var result = ResolvedDependencies()
        let targetPlatform = platform(for: target)

        for dependency in target.dependencies {
            if let dependencyTarget = resolveTargetDependency(dependency) {
                switch dependencyTarget.product {
                case .macro:
                    result.pluginDeps.append(try productLabel(for: dependencyTarget))
                case .framework where target.product == .app || isExtensionProduct(target.product):
                    if let library = try libraryLabel(for: dependencyTarget) {
                        result.codeDeps.append(library)
                    }
                    result.frameworkDeps.append(try productLabel(for: dependencyTarget))
                case _ where target.product == .app && isExtensionProduct(dependencyTarget.product):
                    result.extensionDeps.append(try embeddedExtensionLabel(for: dependencyTarget, app: target))
                case .bundle:
                    if let resource = try resourceLabel(for: dependencyTarget) {
                        result.resourceDeps.append(resource)
                    }
                case .app where target.product == .unitTests || target.product == .uiTests:
                    result.testHost = try productLabel(for: dependencyTarget)
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
        result.frameworkDeps = Array(Set(result.frameworkDeps)).sorted()
        result.extensionDeps = Array(Set(result.extensionDeps)).sorted()
        result.resourceDeps = Array(Set(result.resourceDeps)).sorted()
        result.sdkFrameworks = Array(Set(result.sdkFrameworks)).sorted()
        result.weakSdkFrameworks = Array(Set(result.weakSdkFrameworks)).sorted()
        result.sdkDylibs = Array(Set(result.sdkDylibs)).sorted()
        return result
    }

    private func importsXCTestUnconditionally(in sourcePaths: [String]) -> Bool {
        sourcePaths.contains { path in
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
                return false
            }
            return importsXCTestUnconditionally(inContent: content)
        }
    }

    private func importsXCTestUnconditionally(inContent content: String) -> Bool {
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

    private func binaryImportDepsReferencedBySources(for target: TuistTarget, packagePath: String) throws -> [BazelLabel] {
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

    private func importedModuleNames(in sourcePaths: [String]) -> Set<String> {
        sourcePaths.reduce(into: Set<String>()) { result, path in
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
                return
            }
            result.formUnion(captures(pattern: #"(?m)^\s*(?:@_exported\s+)?import\s+(?:(?:class|struct|enum|protocol|func|var|typealias)\s+)?([A-Za-z_][A-Za-z0-9_]*)"#, in: content))
            result.formUnion(captures(pattern: #"@import\s+([A-Za-z_][A-Za-z0-9_]*)"#, in: content))
            result.formUnion(captures(pattern: #"#import\s+<([A-Za-z_][A-Za-z0-9_]*)/"#, in: content))
        }
    }

    private func captures(pattern: String, in value: String) -> [String] {
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

    private func firstMatch(pattern: String, in value: String) -> String? {
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

    private func replacingMatches(
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

    private func isExtensionProduct(_ product: ProductType) -> Bool {
        switch product {
        case .appExtension, .extensionKitExtension, .messagesExtension, .stickerPackExtension, .tvTopShelfExtension:
            true
        case .app, .framework, .staticFramework, .staticLibrary, .dynamicLibrary, .macro, .bundle, .unitTests, .uiTests, .unsupported:
            false
        }
    }

    private enum ApplePlatform {
        case ios
        case macOS
        case tvOS
        case watchOS
    }

    private func platform(for target: TuistTarget) -> ApplePlatform {
        let destinations = Set(target.destinations)
        if destinations.contains("appleWatch") {
            return .watchOS
        }
        if destinations.contains("appleTv") {
            return .tvOS
        }
        let iosDestinations: Set<String> = ["iPhone", "iPad", "macWithiPadDesign"]
        if destinations.contains("mac"), destinations.isDisjoint(with: iosDestinations) {
            return .macOS
        }
        return .ios
    }

    private func minimumOSVersion(for platform: ApplePlatform) -> String {
        switch platform {
        case .ios, .tvOS:
            "17.0"
        case .macOS:
            "14.0"
        case .watchOS:
            "9.0"
        }
    }

    private func embeddedExtensionLabel(for extensionTarget: TuistTarget, app: TuistTarget) throws -> BazelLabel {
        if requiresAppSpecificExtensionBundle(extensionTarget, app: app) {
            return BazelLabel(
                package: try paths.packagePath(for: extensionTarget.projectPath),
                name: appSpecificExtensionName(for: extensionTarget, app: app)
            )
        }
        return try productLabel(for: extensionTarget)
    }

    private func requiresAppSpecificExtensionBundle(_ extensionTarget: TuistTarget, app: TuistTarget) -> Bool {
        let appBundleId = app.bundleId ?? defaultBundleId(for: app)
        let extensionBundleId = extensionTarget.bundleId ?? defaultBundleId(for: extensionTarget)
        return !extensionBundleId.hasPrefix("\(appBundleId).")
    }

    private func appSpecificExtensionName(for extensionTarget: TuistTarget, app: TuistTarget) -> String {
        "_\(sanitizedModuleName(app.name))_\(sanitizedModuleName(extensionTarget.name))"
    }

    private func appSpecificExtensionBundleId(for extensionTarget: TuistTarget, app: TuistTarget) -> String {
        let appBundleId = app.bundleId ?? defaultBundleId(for: app)
        return "\(appBundleId).\(sanitizedModuleName(extensionTarget.productName))"
    }

    private func resolveTargetDependency(_ dependency: TuistDependency) -> TuistTarget? {
        switch dependency {
        case let .target(name):
            targetsByName[name]
        case let .project(target, path):
            targetsByPathAndName[indexKey(path: path, name: target)] ?? targetsByName[target]
        case .framework, .xcframework, .library, .package(_, _), .sdk, .xctest:
            nil
        }
    }

    private struct SDKDependency {
        var sdkFrameworks: [String] = []
        var weakSdkFrameworks: [String] = []
        var sdkDylibs: [String] = []
        var linkopts: [String] = []
    }

    private func sdkDependency(for name: String, status: String?) -> SDKDependency {
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

    private func binaryImportName(for path: String) -> String {
        "_\(sanitizedModuleName(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent))Import"
    }

    private func xcframeworkImportName(for path: String) -> String {
        "_\(sanitizedModuleName(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent))Import"
    }

    private func xcframeworkImport(for path: String) throws -> XCFrameworkImport {
        try XCFrameworkImport(path: path)
    }

    private struct XCFrameworkImport: Hashable {
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

        private static func kind(at url: URL) throws -> Kind {
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

        private static func containsSwiftModule(at url: URL) -> Bool {
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

    private struct LibraryImport: Hashable {
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
