import Foundation

extension BazelGenerator {
    struct ResolvedDependencies {
        var codeDeps: [BazelLabel] = []
        var pluginDeps: [BazelLabel] = []
        var frameworkDeps: [BazelLabel] = []
        var extensionDeps: [BazelLabel] = []
        var resourceDeps: [BazelLabel] = []
        var linkopts: [String] = []
        var includeDeveloperSearchPaths = false
        var testHost: BazelLabel?
    }

    func makeDependencyResolver() -> BazelDependencyResolver {
        BazelDependencyResolver(
            graph: graph,
            paths: paths,
            resourceAccessors: resourceAccessors,
            targetsByName: targetsByName,
            targetsByPathAndName: targetsByPathAndName,
            remoteSwiftPackageProductLabels: remoteSwiftPackageProductLabels
        )
    }

    mutating func resolvedDependencies(for target: TuistTarget, packagePath: String) throws -> ResolvedDependencies {
        var resolver = makeDependencyResolver()
        let result = try resolver.resolvedDependencies(for: target, packagePath: packagePath)
        warnings.append(contentsOf: resolver.warnings)
        return result
    }

    func binaryImportDepsReferencedBySources(for target: TuistTarget, packagePath: String) throws -> [BazelLabel] {
        try makeDependencyResolver().binaryImportDepsReferencedBySources(for: target, packagePath: packagePath)
    }

    func isExtensionProduct(_ product: ProductType) -> Bool {
        BazelDependencyResolver.isExtensionProduct(product)
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
}
