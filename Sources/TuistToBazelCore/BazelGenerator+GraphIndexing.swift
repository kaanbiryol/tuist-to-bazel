import Foundation

extension BazelGenerator {
    func validateSupportedGraph() throws {
        if let localPackage = graph.localSwiftPackagePaths.first {
            throw ConversionError.unsupported(
                "local Swift package conversion is not supported: \(localPackage); migrate it to Bazel separately"
            )
        }

        let unsupportedSourceExtensions: Set<String> = ["c", "cc", "cpp", "cxx", "m", "mm", "s", "asm"]
        for target in graph.projects.flatMap(\.targets) {
            if target.product == .unsupported {
                throw ConversionError.unsupported("target \(target.name) uses an unsupported product")
            }

            let destinations = Set(target.destinations)
            let removedDestinations = destinations.intersection(["appleTv", "appleWatch", "appleVision"])
            let supportedDestinations = destinations.intersection(["iPhone", "iPad", "mac", "macWithiPadDesign"])
            if supportedDestinations.isEmpty, let destination = removedDestinations.sorted().first {
                throw ConversionError.unsupported(
                    "target \(target.name) uses unsupported destination \(destination); only iOS and macOS are supported"
                )
            }

            if target.product == .appExtension, Self.resolvePlatform(for: target) != .ios {
                throw ConversionError.unsupported(
                    "app extension target \(target.name) is not an iOS extension"
                )
            }

            if let source = target.sources.first(where: {
                unsupportedSourceExtensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased())
            }) {
                throw ConversionError.unsupported(
                    "target \(target.name) contains non-Swift source \(source); Objective-C, C, and C++ sources are not supported"
                )
            }

            if let header = target.headers.first {
                throw ConversionError.unsupported(
                    "target \(target.name) contains header \(header); Objective-C and mixed-language targets are not supported"
                )
            }

            if let model = target.coreDataModelPaths.first {
                throw ConversionError.unsupported(
                    "target \(target.name) contains Core Data model \(model); Core Data generation is not supported"
                )
            }

            for dependency in target.dependencies {
                if case let .unsupported(description) = dependency {
                    throw ConversionError.unsupported(
                        "target \(target.name) uses unsupported dependency: \(description); use an XCFramework instead"
                    )
                }
            }
        }
    }

    mutating func indexTargets() {
        for target in graph.projects.flatMap(\.targets) {
            targetsByName[target.name] = target
            targetsByPathAndName[indexKey(path: target.projectPath, name: target.name)] = target
        }

        for target in graph.projects.flatMap(\.targets) where target.product == .unitTests || target.product == .uiTests {
            for dependency in target.dependencies {
                if let resolved = resolveTargetDependency(dependency) {
                    targetsWithTestConsumers.insert(resolved.name)
                }
            }
        }

        for target in graph.projects.flatMap(\.targets) where isExtensionProduct(target.product) {
            for dependency in target.dependencies {
                if let resolved = resolveTargetDependency(dependency),
                   resolved.product == .framework || resolved.product == .staticFramework {
                    extensionSafeTargets.insert(targetIdentity(resolved))
                }
            }
        }

    }

    func indexKey(path: String, name: String) -> String {
        BazelDependencyResolver.indexKey(path: path, name: name)
    }

    func targetIdentity(_ target: TuistTarget) -> String {
        BazelDependencyResolver.targetIdentity(target)
    }

    mutating func indexRemoteSwiftPackages() throws {
        remoteSwiftPackageRepositories = orderedUnique(
            allRemoteSwiftPackages().map { remoteSwiftPackageRepositoryName(for: $0.url) }
        ).sorted()

        let packageDependencyProducts = graph.projects
            .flatMap(\.targets)
            .flatMap(\.dependencies)
            .compactMap { dependency -> String? in
                guard case let .package(product, _) = dependency else {
                    return nil
                }
                return product
            }
        guard allRemoteSwiftPackages().count == 1,
              let repository = remoteSwiftPackageRepositories.first else {
            if allRemoteSwiftPackages().count > 1 {
                warnings.append("remote Swift package products are not generated because product-to-package mapping is ambiguous")
            }
            return
        }

        for product in orderedUnique(packageDependencyProducts) {
            remoteSwiftPackageProductLabels[product] = BazelLabel(package: "@\(repository)", name: product)
        }
    }

    mutating func renderRemoteSwiftPackageSupportFiles() throws {
        guard !allRemoteSwiftPackages().isEmpty else {
            return
        }

        generatedFiles[".bazel/SwiftPackages/Package.swift"] = renderRemoteSwiftPackageManifest()
        guard let resolvedURL = swiftPackageResolvedURL() else {
            warnings.append("remote Swift packages require Package.resolved, but none was found")
            return
        }
        let resolved = try String(contentsOf: resolvedURL, encoding: .utf8)
        generatedFiles[".bazel/SwiftPackages/Package.resolved"] = try normalizedPackageResolved(resolved)
    }

    func pathForBuildFile(_ packagePath: String) -> String {
        packagePath.isEmpty ? "BUILD.bazel" : "\(packagePath)/BUILD.bazel"
    }

}
