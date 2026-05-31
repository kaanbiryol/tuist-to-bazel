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

    struct SDKDependency {
        var sdkFrameworks: [String] = []
        var weakSdkFrameworks: [String] = []
        var sdkDylibs: [String] = []
        var linkopts: [String] = []
    }

    func makeDependencyResolver() -> BazelDependencyResolver {
        BazelDependencyResolver(
            graph: graph,
            paths: paths,
            resourceAccessors: resourceAccessors,
            targetsByName: targetsByName,
            targetsByPathAndName: targetsByPathAndName,
            localSwiftPackageProductLabels: localSwiftPackageProductLabels,
            remoteSwiftPackageProductLabels: remoteSwiftPackageProductLabels
        )
    }

    mutating func resolvedDependencies(for target: TuistTarget, packagePath: String) throws -> ResolvedDependencies {
        var resolver = makeDependencyResolver()
        let result = try resolver.resolvedDependencies(for: target, packagePath: packagePath)
        warnings.append(contentsOf: resolver.warnings)
        return result
    }

    func importsXCTestUnconditionally(in sourcePaths: [String]) -> Bool {
        makeDependencyResolver().importsXCTestUnconditionally(in: sourcePaths)
    }

    func importsXCTestUnconditionally(inContent content: String) -> Bool {
        BazelDependencyResolver.importsXCTestUnconditionally(inContent: content)
    }

    func binaryImportDepsReferencedBySources(for target: TuistTarget, packagePath: String) throws -> [BazelLabel] {
        try makeDependencyResolver().binaryImportDepsReferencedBySources(for: target, packagePath: packagePath)
    }

    func importedModuleNames(in sourcePaths: [String]) -> Set<String> {
        makeDependencyResolver().importedModuleNames(in: sourcePaths)
    }

    func captures(pattern: String, in value: String) -> [String] {
        BazelDependencyResolver.captures(pattern: pattern, in: value)
    }

    func firstMatch(pattern: String, in value: String) -> String? {
        BazelDependencyResolver.firstMatch(pattern: pattern, in: value)
    }

    func replacingMatches(
        pattern: String,
        in value: String,
        options: NSRegularExpression.Options = [],
        with replacement: String
    ) -> String {
        BazelDependencyResolver.replacingMatches(pattern: pattern, in: value, options: options, with: replacement)
    }

    func isExtensionProduct(_ product: ProductType) -> Bool {
        BazelDependencyResolver.isExtensionProduct(product)
    }

    func embeddedExtensionLabel(for extensionTarget: TuistTarget, app: TuistTarget) throws -> BazelLabel {
        try makeDependencyResolver().embeddedExtensionLabel(for: extensionTarget, app: app)
    }

    func requiresAppSpecificExtensionBundle(_ extensionTarget: TuistTarget, app: TuistTarget) -> Bool {
        makeDependencyResolver().requiresAppSpecificExtensionBundle(extensionTarget, app: app)
    }

    func appSpecificExtensionName(for extensionTarget: TuistTarget, app: TuistTarget) -> String {
        makeDependencyResolver().appSpecificExtensionName(for: extensionTarget, app: app)
    }

    func appSpecificExtensionBundleId(for extensionTarget: TuistTarget, app: TuistTarget) -> String {
        makeDependencyResolver().appSpecificExtensionBundleId(for: extensionTarget, app: app)
    }

    func resolveTargetDependency(_ dependency: TuistDependency) -> TuistTarget? {
        makeDependencyResolver().resolveTargetDependency(dependency)
    }

    func dependencyIsActive(_ dependency: TuistDependency, for platform: ApplePlatform) -> Bool {
        makeDependencyResolver().dependencyIsActive(dependency, for: platform)
    }

    func dependencyCondition(_ dependency: TuistDependency) -> TuistDependencyCondition? {
        BazelDependencyResolver.dependencyCondition(dependency)
    }

    func sdkDependency(for name: String, status: String?) -> SDKDependency {
        makeDependencyResolver().sdkDependency(for: name, status: status)
    }
}
