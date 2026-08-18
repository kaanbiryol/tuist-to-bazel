import Foundation

extension BazelGenerator {
    mutating func renderTarget(_ target: TuistTarget, packagePath: String) throws -> String {
        let rendered: String
        switch target.product {
        case .app:
            rendered = try renderApp(target, packagePath: packagePath)
        case .appClip:
            rendered = try renderAppClip(target, packagePath: packagePath)
        case .appExtension, .extensionKitExtension:
            let original = try renderExtension(target, packagePath: packagePath)
            rendered = try renderWithAppSpecificExtensionBundles(
                target,
                packagePath: packagePath,
                original: original
            )
        case .framework:
            rendered = try renderFramework(target, packagePath: packagePath)
        case .messagesExtension:
            let original = try renderMessagesExtension(target, packagePath: packagePath)
            rendered = try renderWithAppSpecificExtensionBundles(
                target,
                packagePath: packagePath,
                original: original
            )
        case .staticFramework:
            rendered = try renderStaticFramework(target, packagePath: packagePath)
        case .stickerPackExtension:
            let original = try renderStickerPackExtension(target, packagePath: packagePath)
            rendered = try renderWithAppSpecificExtensionBundles(
                target,
                packagePath: packagePath,
                original: original
            )
        case .tvTopShelfExtension:
            let original = try renderTVTopShelfExtension(target, packagePath: packagePath)
            rendered = try renderWithAppSpecificExtensionBundles(
                target,
                packagePath: packagePath,
                original: original
            )
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
        return [
            try renderCoreDataModelIfNeeded(target, packagePath: packagePath),
            rendered,
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n\n")
    }

    mutating func renderApp(_ target: TuistTarget, packagePath: String) throws -> String {
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
        case .visionOS:
            ruleName = "visionos_application"
            families = "    families = [\"vision\"],\n"
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
            \(optionalLabelListAttribute("app_clips", deps.appClipDeps, packagePath: packagePath, indent: 4))\(optionalLabelListAttribute("frameworks", deps.frameworkDeps, packagePath: packagePath, indent: 4))\(optionalLabelAttribute("watch_application", deps.watchApplication, packagePath: packagePath, indent: 4))\(optionalLabelListAttribute("extensions", deps.extensionDeps, packagePath: packagePath, indent: 4))\(optionalLabelListAttribute("resources", deps.resourceDeps + resourceGroupLabelIfNeeded(target, packagePath: packagePath), packagePath: packagePath, indent: 4)))
            """
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n\n")
            .replacingOccurrences(of: ")\n \n", with: ")\n")
    }

    mutating func renderAppClip(_ target: TuistTarget, packagePath: String) throws -> String {
        let deps = try resolvedDependencies(for: target, packagePath: packagePath)
        let platform = platform(for: target)
        if platform != .ios {
            warnings.append("app clip target \(target.name) is expected to target iOS; generated as ios_app_clip")
        }
        return [
            try renderResourceGroupIfNeeded(target, packagePath: packagePath),
            try renderSwiftLibrary(target, packagePath: packagePath, name: libraryName(for: target), testonly: false, manual: true, resolved: deps),
            """
            ios_app_clip(
                name = "\(target.name)",
                bundle_id = "\(target.bundleId ?? defaultBundleId(for: target))",
                families = ["iphone", "ipad"],
            \(infoplistsAttribute(target, packagePath: packagePath, indent: 4))    minimum_os_version = "\(minimumOSVersion(for: .ios))",
                deps = [":\(libraryName(for: target))"],
            \(optionalLabelListAttribute("frameworks", deps.frameworkDeps, packagePath: packagePath, indent: 4))\(optionalLabelListAttribute("extensions", deps.extensionDeps, packagePath: packagePath, indent: 4))\(optionalLabelListAttribute("resources", deps.resourceDeps + resourceGroupLabelIfNeeded(target, packagePath: packagePath), packagePath: packagePath, indent: 4)))
            """
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n\n")
            .replacingOccurrences(of: ")\n \n", with: ")\n")
    }

    mutating func renderExtension(_ target: TuistTarget, packagePath: String) throws -> String {
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
        case .visionOS:
            warnings.append("visionOS extension target \(target.name) is decoded but not generated yet")
            return "# \(target.name) skipped: visionOS extension generation is not implemented yet"
        }
        return try renderExtensionRule(
            target,
            packagePath: packagePath,
            ruleName: ruleName,
            extraAttributes: extensionExtraAttributes(for: target, platform: platform)
        )
    }

    mutating func renderMessagesExtension(_ target: TuistTarget, packagePath: String) throws -> String {
        try renderExtensionRule(target, packagePath: packagePath, ruleName: "ios_imessage_extension")
    }

    mutating func renderExtensionRule(
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

    mutating func renderExtensionBundleRule(
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

    mutating func renderWithAppSpecificExtensionBundles(
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

    mutating func renderAppSpecificExtensionBundle(
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
            case .visionOS:
                warnings.append("visionOS extension target \(target.name) is decoded but not generated yet")
                return "# \(consumer.wrapperName) skipped: visionOS extension generation is not implemented yet"
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
        case .app, .appClip, .framework, .staticFramework, .staticLibrary, .dynamicLibrary, .macro, .bundle, .unitTests, .uiTests, .unsupported:
            return ""
        }
    }

    func appSpecificExtensionTarget(
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

    func extensionExtraAttributes(for target: TuistTarget, platform: ApplePlatform) -> String {
        var attributes = ""
        if target.product == .extensionKitExtension {
            attributes += "    extensionkit_extension = True,\n"
        }
        if platform == .watchOS && target.product == .appExtension {
            attributes += "    application_extension = True,\n"
        }
        return attributes
    }

    mutating func renderStickerPackExtensionBundle(
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

    mutating func renderStickerPackExtension(_ target: TuistTarget, packagePath: String) throws -> String {
        try renderStickerPackExtensionBundle(
            target,
            packagePath: packagePath,
            name: target.name,
            bundleId: target.bundleId ?? defaultBundleId(for: target),
            infoPlistTarget: target
        )
    }

    mutating func renderTVTopShelfExtension(_ target: TuistTarget, packagePath: String) throws -> String {
        try renderTVTopShelfExtensionBundle(
            target,
            packagePath: packagePath,
            name: target.name,
            bundleId: target.bundleId ?? defaultBundleId(for: target),
            infoPlistTarget: target
        )
    }

    mutating func renderTVTopShelfExtensionBundle(
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

    mutating func renderFramework(_ target: TuistTarget, packagePath: String) throws -> String {
        switch platform(for: target) {
        case .ios:
            return try renderIOSFramework(target, packagePath: packagePath)
        case .macOS:
            return try renderMacOSFramework(target, packagePath: packagePath)
        case .tvOS:
            return try renderTVOSFramework(target, packagePath: packagePath)
        case .watchOS:
            return try renderWatchOSFramework(target, packagePath: packagePath)
        case .visionOS:
            return try renderVisionOSFramework(target, packagePath: packagePath)
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
            \(bundleNameAttribute(target, indent: 4))    bundle_id = "\(target.bundleId ?? defaultBundleId(for: target))",
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
            \(bundleNameAttribute(target, indent: 4))    bundle_id = "\(target.bundleId ?? defaultBundleId(for: target))",
            \(extensionSafeAttribute(target, indent: 4))\(infoplistsAttribute(target, packagePath: packagePath, indent: 4))    minimum_os_version = "\(minimumOSVersion(for: platform))",
            \(productDeps)\(optionalLabelListAttribute("frameworks", deps.frameworkDeps, packagePath: packagePath, indent: 4))
            \(optionalLabelListAttribute("resources", deps.resourceDeps + resourceGroupLabelIfNeeded(target, packagePath: packagePath), packagePath: packagePath, indent: 4)))
            """
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n\n")
            .replacingOccurrences(of: ")\n \n", with: ")\n")
    }

    mutating func renderTVOSFramework(_ target: TuistTarget, packagePath: String) throws -> String {
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

    mutating func renderWatchOSFramework(_ target: TuistTarget, packagePath: String) throws -> String {
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

    mutating func renderVisionOSFramework(_ target: TuistTarget, packagePath: String) throws -> String {
        let deps = try resolvedDependencies(for: target, packagePath: packagePath)
        let platform = ApplePlatform.visionOS
        let libraryBlock = try frameworkLibraryBlockIfNeeded(target, packagePath: packagePath, deps: deps)
        let productDeps = hasSwiftLibrary(for: target) ? "    deps = [\":\(libraryName(for: target))\"],\n" : ""
        return [
            try renderResourceGroupIfNeeded(target, packagePath: packagePath),
            libraryBlock,
            """
            visionos_framework(
                name = "\(target.name)",
            \(bundleNameAttribute(target, indent: 4))    bundle_id = "\(target.bundleId ?? defaultBundleId(for: target))",
                families = ["vision"],
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
        case .tvOS:
            ruleName = "tvos_unit_test"
        case .watchOS:
            ruleName = "watchos_unit_test"
        case .visionOS:
            ruleName = "visionos_unit_test"
        }
        var lines = [
            "\(ruleName)(",
            "    name = \"\(target.name)\",",
            "    bundle_id = \"\(target.bundleId ?? defaultBundleId(for: target))\",",
        ]
        if platform == .visionOS {
            warnings.append("visionOS unit test target \(target.name) is generated as manual because rules_apple 4.5.2 fails during analysis")
            lines.append("    tags = [\"manual\"],")
        }
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
        case .tvOS:
            ruleName = "tvos_ui_test"
        case .watchOS:
            ruleName = "watchos_ui_test"
        case .visionOS:
            ruleName = "visionos_ui_test"
        }
        var lines = [
            "\(ruleName)(",
            "    name = \"\(target.name)\",",
            "    bundle_id = \"\(target.bundleId ?? defaultBundleId(for: target))\",",
        ]
        if platform == .visionOS {
            warnings.append("visionOS ui test target \(target.name) is generated as manual because rules_apple 4.5.2 may fail during analysis")
            lines.append("    tags = [\"manual\"],")
        }
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
        case .macOS, .tvOS, .watchOS, .visionOS:
            """
            \(testRunnerRuleName(for: platform))(
                name = "\(testRunnerName(for: platform))",
            )
            """
        }
    }

}
