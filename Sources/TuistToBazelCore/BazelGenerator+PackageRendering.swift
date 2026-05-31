import Foundation

extension BazelGenerator {
    mutating func renderPackageBuild(
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

        for platform in testRunnerPlatforms(for: targets) {
            build.add()
            build.addBlock(renderTestRunner(for: platform))
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

    func renderLocalSwiftPackageBuild(packagePath: String, manifest: SwiftPackageManifest) throws -> String {
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

    func localSwiftPackageTargetNamesToGenerate(_ manifest: SwiftPackageManifest) -> Set<String> {
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

    func loadsFor(_ targets: [TuistTarget], packagePath: String) throws -> [String] {
        var iosRules: Set<String> = []
        var macOSRules: Set<String> = []
        var tvOSRules: Set<String> = []
        var watchOSRules: Set<String> = []
        var visionOSRules: Set<String> = []
        var swiftRules: Set<String> = []
        var testRunnerPlatforms: Set<ApplePlatform> = []
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
            needsResources = needsResources || !target.resources.isEmpty || !target.coreDataModels.isEmpty || target.product == .bundle
            switch target.product {
            case .app:
                switch platform(for: target) {
                case .tvOS:
                    tvOSRules.insert("tvos_application")
                case .watchOS:
                    watchOSRules.insert("watchos_application")
                case .visionOS:
                    visionOSRules.insert("visionos_application")
                case .ios, .macOS:
                    iosRules.insert("ios_application")
                }
            case .appClip:
                iosRules.insert("ios_app_clip")
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
                case .visionOS:
                    break
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
                case .visionOS:
                    break
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
                case .visionOS:
                    visionOSRules.insert("visionos_framework")
                }
            case .messagesExtension:
                iosRules.insert("ios_imessage_extension")
            case .staticFramework:
                switch platform(for: target) {
                case .ios:
                    iosRules.insert("ios_static_framework")
                case .macOS:
                    macOSRules.insert("macos_static_framework")
                case .tvOS:
                    tvOSRules.insert("tvos_static_framework")
                case .watchOS:
                    watchOSRules.insert("watchos_static_framework")
                case .visionOS:
                    visionOSRules.insert("visionos_static_framework")
                }
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
                    testRunnerPlatforms.insert(.ios)
                case .macOS:
                    macOSRules.insert("macos_unit_test")
                case .tvOS:
                    tvOSRules.insert("tvos_unit_test")
                case .watchOS:
                    watchOSRules.insert("watchos_unit_test")
                case .visionOS:
                    visionOSRules.insert("visionos_unit_test")
                }
            case .uiTests:
                let platform = platform(for: target)
                testRunnerPlatforms.insert(platform)
                switch platform {
                case .ios:
                    iosRules.insert("ios_ui_test")
                case .macOS:
                    macOSRules.insert("macos_ui_test")
                case .tvOS:
                    tvOSRules.insert("tvos_ui_test")
                case .watchOS:
                    watchOSRules.insert("watchos_ui_test")
                case .visionOS:
                    visionOSRules.insert("visionos_ui_test")
                }
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
        for platform in testRunnerPlatforms.sorted(by: { testRunnerRuleName(for: $0) < testRunnerRuleName(for: $1) }) {
            let ruleName = testRunnerRuleName(for: platform)
            loads.append("load(\"@build_bazel_rules_apple//apple/testing/default_runner:\(ruleName).bzl\", \"\(ruleName)\")")
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
        if !visionOSRules.isEmpty {
            let ruleNames = visionOSRules.sorted().map(Starlark.quote).joined(separator: ", ")
            loads.append("load(\"@build_bazel_rules_apple//apple:visionos.bzl\", \(ruleNames))")
        }
        if needsResources {
            var resourceRules = ["apple_bundle_import", "apple_resource_bundle", "apple_resource_group"]
            if targets.contains(where: { !$0.coreDataModels.isEmpty }) {
                resourceRules.append("apple_core_data_model")
            }
            let ruleNames = resourceRules.sorted().map(Starlark.quote).joined(separator: ", ")
            loads.append("load(\"@build_bazel_rules_apple//apple:resources.bzl\", \(ruleNames))")
        }
        return loads
    }

}
