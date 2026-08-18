import Foundation

extension BazelGenerator {
    func renderModule() -> String {
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

    func renderRemoteSwiftPackageManifest() -> String {
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

    func swiftPackageResolvedURL() -> URL? {
        [
            paths.root.appendingPathComponent("Package.resolved"),
            paths.root.appendingPathComponent(".package.resolved"),
            paths.root.appendingPathComponent("Tuist/Package.resolved"),
        ].first { fileManager.fileExists(atPath: $0.path) }
    }

    func normalizedPackageResolved(_ content: String) throws -> String {
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

    func remoteSwiftPackageRepositoryName(for url: String) -> String {
        let trimmed = url.hasSuffix(".git") ? String(url.dropLast(4)) : url
        let lastComponent = URL(string: trimmed)?.lastPathComponent
            ?? trimmed.split(separator: "/").last.map(String.init)
            ?? trimmed
        return "swiftpkg_\(packageIdentityName(for: lastComponent))"
    }

    func packageIdentityName(for value: String) -> String {
        sanitizedModuleName(value.lowercased())
    }

    func allRemoteSwiftPackages() -> [TuistRemoteSwiftPackage] {
        var seen: Set<TuistRemoteSwiftPackage> = []
        return graph.remoteSwiftPackages
            .filter { seen.insert($0).inserted }
    }

    func orderedUnique<T: Hashable>(_ values: [T]) -> [T] {
        var seen: Set<T> = []
        return values.filter { seen.insert($0).inserted }
    }

    mutating func renderRootXcodeproj() throws -> (loads: [String], block: String) {
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

    func isLibraryTopLevelProduct(_ product: ProductType) -> Bool {
        switch product {
        case .framework, .staticFramework, .dynamicLibrary, .staticLibrary:
            true
        case .app, .appExtension, .macro, .bundle, .unitTests, .uiTests, .unsupported:
            false
        }
    }
}
