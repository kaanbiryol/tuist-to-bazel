import Foundation

public struct Converter {
    public init() {}

    public func convert(_ input: ConversionInput) throws -> ConversionResult {
        let data = try Data(contentsOf: input.graphPath)
        var graph = try TuistGraphParser().parse(data: data)
        try graph.routeExternalSwiftPackageProjects(rootPath: input.rootPath)
        let paths = PathContext(root: input.rootPath, output: input.outputPath)
        var generator = BazelGenerator(graph: graph, paths: paths)
        let rendered = try generator.render()

        let plannedFiles = rendered.files
            .map { relativePath, contents in
                (
                    relativePath: relativePath,
                    contents: contents,
                    outputURL: input.outputPath.appendingPathComponent(relativePath)
                )
            }
            .sorted { $0.relativePath < $1.relativePath }

        if !input.force,
           let conflict = plannedFiles.first(where: { FileManager.default.fileExists(atPath: $0.outputURL.path) }) {
            throw ConversionError.outputExists(conflict.outputURL)
        }

        var written: [URL] = []
        for file in plannedFiles {
            try FileManager.default.createDirectory(
                at: file.outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try file.contents.write(to: file.outputURL, atomically: true, encoding: .utf8)
            written.append(file.outputURL)
        }

        return ConversionResult(writtenFiles: written, warnings: rendered.warnings)
    }
}
