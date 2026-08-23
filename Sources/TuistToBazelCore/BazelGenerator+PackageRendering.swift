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

    func loadsFor(_ targets: [TuistTarget], packagePath: String) throws -> [String] {
        var iosRules: Set<String> = []
        var macOSRules: Set<String> = []
        var swiftRules: Set<String> = []
        var testRunnerPlatforms: Set<ApplePlatform> = []
        var needsResources = false
        var appleImportRules: Set<String> = []

        for target in targets {
            if target.product == .macro {
                swiftRules.insert("swift_compiler_plugin")
            } else if target.product.isSwiftBacked {
                swiftRules.insert("swift_library")
            }
            needsResources = needsResources || !target.resources.isEmpty || target.product == .bundle
            switch target.product {
            case .app:
                switch platform(for: target) {
                case .ios:
                    iosRules.insert("ios_application")
                case .macOS:
                    macOSRules.insert("macos_application")
                }
            case .appExtension:
                iosRules.insert("ios_extension")
            case .framework:
                switch platform(for: target) {
                case .ios:
                    iosRules.insert("ios_framework")
                case .macOS:
                    macOSRules.insert("macos_framework")
                }
            case .staticFramework:
                switch platform(for: target) {
                case .ios:
                    iosRules.insert("ios_static_framework")
                case .macOS:
                    macOSRules.insert("macos_static_framework")
                }
            case .macro:
                break
            case .unitTests:
                switch platform(for: target) {
                case .ios:
                    iosRules.insert("ios_unit_test")
                    testRunnerPlatforms.insert(.ios)
                case .macOS:
                    macOSRules.insert("macos_unit_test")
                }
            case .uiTests:
                let platform = platform(for: target)
                testRunnerPlatforms.insert(platform)
                switch platform {
                case .ios:
                    iosRules.insert("ios_ui_test")
                case .macOS:
                    macOSRules.insert("macos_ui_test")
                }
            case .staticLibrary, .dynamicLibrary, .bundle, .unsupported:
                break
            }
        }

        let dependencyPairs = try dependenciesWithConsumingPackages(for: packagePath, targets: targets)
        for pair in dependencyPairs {
            for dependency in pair.dependencies {
                switch dependency {
                case let .xcframework(path):
                    if binaryImportPackage(for: path, consumingPackage: pair.packagePath) == packagePath {
                        appleImportRules.insert(try xcframeworkImport(for: path).ruleName)
                    }
                case .target, .project, .package, .sdk, .xctest, .unsupported:
                    break
                }
            }
        }

        var loads: [String] = []
        if !swiftRules.isEmpty {
            let ruleNames = swiftRules.sorted().map(Starlark.quote).joined(separator: ", ")
            loads.append("load(\"@build_bazel_rules_swift//swift:swift.bzl\", \(ruleNames))")
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
        if needsResources {
            let resourceRules = ["apple_bundle_import", "apple_resource_bundle", "apple_resource_group"]
            let ruleNames = resourceRules.sorted().map(Starlark.quote).joined(separator: ", ")
            loads.append("load(\"@build_bazel_rules_apple//apple:resources.bzl\", \(ruleNames))")
        }
        return loads
    }

}
