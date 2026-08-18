import Foundation

extension BazelGenerator {
    func renderBinaryImports(packagePath: String, targets: [TuistTarget]) throws -> [String] {
        try BazelBinaryImportRenderer(graph: graph, paths: paths).render(packagePath: packagePath, targets: targets)
    }

    func dependenciesWithConsumingPackages(
        for packagePath: String,
        targets: [TuistTarget]
    ) throws -> [(packagePath: String, dependencies: [TuistDependency])] {
        try BazelBinaryImportRenderer(graph: graph, paths: paths)
            .dependenciesWithConsumingPackages(for: packagePath, targets: targets)
    }

    func binaryImportPackage(for path: String, consumingPackage: String) -> String {
        BazelBinaryImportRenderer.package(for: path, consumingPackage: consumingPackage, paths: paths)
    }

    func xcframeworkImport(for path: String) throws -> BazelXCFrameworkImport {
        try BazelXCFrameworkImport(path: path)
    }
}
