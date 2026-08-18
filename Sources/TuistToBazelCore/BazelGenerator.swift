import Foundation

struct BazelGenerator {
    let graph: TuistGraph
    let paths: PathContext
    let fileManager = FileManager.default
    let resourceAccessors = ResourceAccessorGenerator()
    var warnings: [String] = []
    var generatedFiles: [String: String] = [:]
    var targetsByName: [String: TuistTarget] = [:]
    var targetsByPathAndName: [String: TuistTarget] = [:]
    var targetsWithTestConsumers: Set<String> = []
    var extensionSafeTargets: Set<String> = []
    var remoteSwiftPackageRepositories: [String] = []
    var remoteSwiftPackageProductLabels: [String: BazelLabel] = [:]

    init(graph: TuistGraph, paths: PathContext) {
        self.graph = graph
        self.paths = paths
    }

    mutating func render() throws -> (files: [String: String], warnings: [String]) {
        try validateSupportedGraph()
        indexTargets()
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
        for (path, content) in generatedFiles {
            files[path] = content
        }

        return (files, warnings)
    }
}
