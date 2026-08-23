import Foundation

extension BazelGenerator {
    mutating func renderTarget(_ target: TuistTarget, packagePath: String) throws -> String {
        let rendered: String
        switch target.product {
        case .app:
            rendered = try renderApp(target, packagePath: packagePath)
        case .appExtension:
            rendered = try renderExtension(target, packagePath: packagePath)
        case .framework:
            rendered = try renderFramework(target, packagePath: packagePath)
        case .staticFramework:
            rendered = try renderStaticFramework(target, packagePath: packagePath)
        case .staticLibrary, .dynamicLibrary:
            rendered = try renderLibrary(target, packagePath: packagePath)
        case .macro:
            rendered = try renderCompilerPlugin(target, packagePath: packagePath)
        case .bundle:
            rendered = try renderResourceBundle(target, packagePath: packagePath)
        case .unitTests:
            rendered = try renderUnitTest(target, packagePath: packagePath)
        case .uiTests:
            rendered = try renderUITest(target, packagePath: packagePath)
        case .unsupported:
            warnings.append("target \(target.name) has an unsupported product and was skipped")
            return "# \(target.name) skipped: unsupported product"
        }
        return rendered
    }

    mutating func renderApp(_ target: TuistTarget, packagePath: String) throws -> String {
        let deps = try resolvedDependencies(for: target, packagePath: packagePath)
        let platform = platform(for: target)
        let ruleName: String
        let families: String
        switch platform {
        case .ios:
            ruleName = "ios_application"
            families = "    families = [\"iphone\", \"ipad\"],\n"
        case .macOS:
            ruleName = "macos_application"
            families = ""
        }
        return [
            try renderResourceGroupIfNeeded(target, packagePath: packagePath),
            try renderSwiftLibrary(target, packagePath: packagePath, name: libraryName(for: target), testonly: false, manual: true, resolved: deps),
            """
            \(ruleName)(
                name = "\(target.name)",
                bundle_id = "\(resolvedBundleId(for: target))",
            \(families)\(infoplistsAttribute(target, packagePath: packagePath, indent: 4))    minimum_os_version = "\(minimumOSVersion(for: platform))",
                deps = [":\(libraryName(for: target))"],
            \(optionalLabelListAttribute("frameworks", deps.frameworkDeps, packagePath: packagePath, indent: 4))\(optionalLabelListAttribute("extensions", deps.extensionDeps, packagePath: packagePath, indent: 4))\(optionalLabelListAttribute("resources", deps.resourceDeps + resourceGroupLabelIfNeeded(target, packagePath: packagePath), packagePath: packagePath, indent: 4)))
            """
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n\n")
            .replacingOccurrences(of: ")\n \n", with: ")\n")
    }

    mutating func renderExtension(_ target: TuistTarget, packagePath: String) throws -> String {
        let deps = try resolvedDependencies(for: target, packagePath: packagePath)
        return [
            try renderResourceGroupIfNeeded(target, packagePath: packagePath),
            try renderSwiftLibrary(target, packagePath: packagePath, name: libraryName(for: target), testonly: false, manual: true, resolved: deps),
            """
            ios_extension(
                name = "\(target.name)",
                bundle_id = "\(resolvedBundleId(for: target))",
            \(familiesAttribute(for: .ios, indent: 4))\(infoplistsAttribute(target, packagePath: packagePath, indent: 4))    minimum_os_version = "\(minimumOSVersion(for: .ios))",
                deps = [":\(libraryName(for: target))"],
            \(optionalLabelListAttribute("frameworks", deps.frameworkDeps, packagePath: packagePath, indent: 4))\(optionalLabelListAttribute("resources", deps.resourceDeps + resourceGroupLabelIfNeeded(target, packagePath: packagePath), packagePath: packagePath, indent: 4)))
            """,
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n\n")
            .replacingOccurrences(of: ")\n \n", with: ")\n")
    }

    mutating func renderFramework(_ target: TuistTarget, packagePath: String) throws -> String {
        switch platform(for: target) {
        case .ios:
            return try renderIOSFramework(target, packagePath: packagePath)
        case .macOS:
            return try renderMacOSFramework(target, packagePath: packagePath)
        }
    }

    mutating func renderIOSFramework(_ target: TuistTarget, packagePath: String) throws -> String {
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
            \(bundleNameAttribute(target, indent: 4))    bundle_id = "\(resolvedBundleId(for: target))",
                families = ["iphone", "ipad"],
            \(extensionSafeAttribute(target, indent: 4))\(infoplistsAttribute(target, packagePath: packagePath, indent: 4))    minimum_os_version = "\(minimumOSVersion(for: platform))",
            \(productDeps)\(optionalLabelListAttribute("frameworks", deps.frameworkDeps, packagePath: packagePath, indent: 4))
            \(optionalLabelListAttribute("resources", deps.resourceDeps + resourceGroupLabelIfNeeded(target, packagePath: packagePath), packagePath: packagePath, indent: 4)))
            """
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n\n")
            .replacingOccurrences(of: ")\n \n", with: ")\n")
    }

    mutating func renderMacOSFramework(_ target: TuistTarget, packagePath: String) throws -> String {
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
            \(bundleNameAttribute(target, indent: 4))    bundle_id = "\(resolvedBundleId(for: target))",
            \(extensionSafeAttribute(target, indent: 4))\(infoplistsAttribute(target, packagePath: packagePath, indent: 4))    minimum_os_version = "\(minimumOSVersion(for: platform))",
            \(productDeps)\(optionalLabelListAttribute("frameworks", deps.frameworkDeps, packagePath: packagePath, indent: 4))
            \(optionalLabelListAttribute("resources", deps.resourceDeps + resourceGroupLabelIfNeeded(target, packagePath: packagePath), packagePath: packagePath, indent: 4)))
            """
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n\n")
            .replacingOccurrences(of: ")\n \n", with: ")\n")
    }

    mutating func frameworkLibraryBlockIfNeeded(
        _ target: TuistTarget,
        packagePath: String,
        deps: ResolvedDependencies
    ) throws -> String? {
        guard hasSwiftLibrary(for: target) else {
            return nil
        }
        return try renderSwiftLibrary(target, packagePath: packagePath, name: libraryName(for: target), testonly: false, manual: true, resolved: deps)
    }

    func extensionSafeAttribute(_ target: TuistTarget, indent: Int) -> String {
        guard extensionSafeTargets.contains(targetIdentity(target)) else {
            return ""
        }
        return "\(String(repeating: " ", count: indent))extension_safe = True,\n"
    }

    func bundleNameAttribute(_ target: TuistTarget, indent: Int) -> String {
        guard target.productName != target.name else {
            return ""
        }
        return "\(String(repeating: " ", count: indent))bundle_name = \"\(target.productName)\",\n"
    }

    mutating func renderStaticFramework(_ target: TuistTarget, packagePath: String) throws -> String {
        let deps = try resolvedDependencies(for: target, packagePath: packagePath)
        let platform = platform(for: target)
        var parts: [String] = []
        if let resources = try renderResourceGroupIfNeeded(target, packagePath: packagePath) {
            parts.append(resources)
        }
        if !hasSwiftLibrary(for: target) {
            warnings.append("static framework \(target.name) has no sources; generated its resources but skipped a static framework wrapper")
            if parts.isEmpty {
                parts.append("# \(target.name) skipped: source-less static framework")
            }
            return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n\n")
        }
        parts.append(try renderSwiftLibrary(target, packagePath: packagePath, name: libraryName(for: target), testonly: false, manual: true, resolved: deps))

        let frameworkDeps = [BazelLabel(package: packagePath, name: libraryName(for: target))]
        parts.append(
            """
            \(staticFrameworkRuleName(for: platform))(
                name = "\(target.name)",
                minimum_os_version = "\(minimumOSVersion(for: platform))",
            \(optionalLabelListAttribute("avoid_deps", deps.codeDeps, packagePath: packagePath, indent: 4))\(optionalLabelListAttribute("deps", frameworkDeps, packagePath: packagePath, indent: 4))\(optionalLabelListAttribute("resources", deps.resourceDeps + resourceGroupLabelIfNeeded(target, packagePath: packagePath), packagePath: packagePath, indent: 4)))
            """
        )
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n\n")
            .replacingOccurrences(of: ")\n \n", with: ")\n")
    }

    mutating func renderLibrary(_ target: TuistTarget, packagePath: String) throws -> String {
        let deps = try resolvedDependencies(for: target, packagePath: packagePath)
        return [
            try renderResourceGroupIfNeeded(target, packagePath: packagePath),
            try renderSwiftLibrary(target, packagePath: packagePath, name: target.name, testonly: false, manual: true, resolved: deps),
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n\n")
    }

    mutating func renderUnitTest(_ target: TuistTarget, packagePath: String) throws -> String {
        let deps = try resolvedDependencies(for: target, packagePath: packagePath)
        let platform = platform(for: target)
        let ruleName: String
        switch platform {
        case .ios:
            ruleName = "ios_unit_test"
        case .macOS:
            ruleName = "macos_unit_test"
        }
        var lines = [
            "\(ruleName)(",
            "    name = \"\(target.name)\",",
            "    bundle_id = \"\(resolvedBundleId(for: target))\",",
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
        if platform == .ios {
            lines.append("    runner = \":\(testRunnerName(for: platform))\",")
        }
        lines.append(")")

        return [
            try renderResourceGroupIfNeeded(target, packagePath: packagePath),
            try renderSwiftLibrary(target, packagePath: packagePath, name: libraryName(for: target), testonly: true, manual: true, resolved: deps),
            lines.joined(separator: "\n"),
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n\n")
    }

    mutating func renderUITest(_ target: TuistTarget, packagePath: String) throws -> String {
        let deps = try resolvedDependencies(for: target, packagePath: packagePath)
        let platform = platform(for: target)
        let ruleName: String
        switch platform {
        case .ios:
            ruleName = "ios_ui_test"
        case .macOS:
            ruleName = "macos_ui_test"
        }
        var lines = [
            "\(ruleName)(",
            "    name = \"\(target.name)\",",
            "    bundle_id = \"\(resolvedBundleId(for: target))\",",
        ]
        if let infoPlistPath = target.infoPlistPath,
           let relative = try? paths.pathRelativeToPackage(infoPlistPath, packagePath: packagePath) {
            lines.append("    infoplists = [\(Starlark.quote(relative))],")
        }
        lines.append("    minimum_os_version = \"\(minimumOSVersion(for: platform))\",")
        lines.append("    deps = [\":\(libraryName(for: target))\"],")
        if let testHost = deps.testHost {
            lines.append("    test_host = \"\(testHost.localDescription(in: packagePath))\",")
        }
        lines.append("    runner = \":\(testRunnerName(for: platform))\",")
        lines.append(")")

        return [
            try renderResourceGroupIfNeeded(target, packagePath: packagePath),
            try renderSwiftLibrary(target, packagePath: packagePath, name: libraryName(for: target), testonly: true, manual: true, resolved: deps),
            lines.joined(separator: "\n"),
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n\n")
    }

    mutating func renderCompilerPlugin(_ target: TuistTarget, packagePath: String) throws -> String {
        let deps = try resolvedDependencies(for: target, packagePath: packagePath)
        let srcs = try sourceLabels(for: target, packagePath: packagePath)
        let compilerOptions = target.swiftLanguageMode.map { ["-swift-version", $0] } ?? []
        let coptsAttribute = compilerOptions.isEmpty
            ? ""
            : "    copts = \(Starlark.orderedList(compilerOptions, indent: 4)),\n"
        let tagsAttribute = "    tags = [\"manual\"],\n"
        let pluginsAttribute = deps.pluginDeps.isEmpty ? "" : "    plugins = \(Starlark.list(deps.pluginDeps.map { $0.localDescription(in: packagePath) }, indent: 4)),\n"

        return """
        swift_compiler_plugin(
            name = "\(target.name)",
            srcs = \(Starlark.list(srcs, indent: 4)),
        \(coptsAttribute)    module_name = "\(sanitizedModuleName(target.productName))",
        \(pluginsAttribute)\(tagsAttribute)    deps = \(Starlark.list(deps.codeDeps.map { $0.localDescription(in: packagePath) }, indent: 4)),
        )
        """
    }

    func testRunnerPlatforms(for targets: [TuistTarget]) -> [ApplePlatform] {
        let platforms = targets.reduce(into: Set<ApplePlatform>()) { result, target in
            if target.product == .unitTests, platform(for: target) == .ios {
                result.insert(.ios)
            }
            if target.product == .uiTests {
                result.insert(platform(for: target))
            }
        }
        return platforms.sorted { testRunnerRuleName(for: $0) < testRunnerRuleName(for: $1) }
    }

    func renderTestRunner(for platform: ApplePlatform) -> String {
        switch platform {
        case .ios:
            """
            ios_test_runner(
                name = "\(testRunnerName(for: platform))",
            )
            """
        case .macOS:
            """
            \(testRunnerRuleName(for: platform))(
                name = "\(testRunnerName(for: platform))",
            )
            """
        }
    }

}
