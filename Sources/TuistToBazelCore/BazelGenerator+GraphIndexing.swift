import Foundation

extension BazelGenerator {
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

        for app in graph.projects.flatMap(\.targets) where app.product == .app || app.product == .appClip {
            for dependency in app.dependencies {
                guard let extensionTarget = resolveTargetDependency(dependency),
                      isExtensionProduct(extensionTarget.product),
                      requiresAppSpecificExtensionBundle(extensionTarget, app: app) else {
                    continue
                }
                let consumer = AppSpecificExtensionConsumer(
                    wrapperName: appSpecificExtensionName(for: extensionTarget, app: app),
                    bundleId: appSpecificExtensionBundleId(for: extensionTarget, app: app)
                )
                let identity = targetIdentity(extensionTarget)
                if appSpecificExtensionConsumers[identity]?.contains(where: { $0.wrapperName == consumer.wrapperName }) != true {
                    appSpecificExtensionConsumers[identity, default: []].append(consumer)
                }
            }
        }
    }

    func indexKey(path: String, name: String) -> String {
        "\(URL(fileURLWithPath: path).standardizedFileURL.path)#\(name)"
    }

    func targetIdentity(_ target: TuistTarget) -> String {
        indexKey(path: target.projectPath, name: target.name)
    }

    mutating func indexLocalSwiftPackages() throws {
        for localPackage in graph.localSwiftPackages {
            let packagePath = try paths.packagePath(for: localPackage.path)
            guard localSwiftPackageManifests[packagePath] == nil else {
                continue
            }
            let manifest = try swiftPackageParser.parse(packagePath: localPackage.path)
            localSwiftPackageManifests[packagePath] = manifest

            let targetNames = localSwiftPackageTargetNamesToGenerate(manifest)
            for product in manifest.products {
                guard let targetName = product.targets.first, product.targets.count == 1, targetNames.contains(targetName) else {
                    warnings.append("local Swift package product \(product.name) is not generated because it has multiple or missing targets")
                    continue
                }
                let label = BazelLabel(package: packagePath, name: targetName)
                if localSwiftPackageProductLabels[product.name] == nil {
                    localSwiftPackageProductLabels[product.name] = label
                } else {
                    warnings.append("local Swift package product \(product.name) is ambiguous")
                }
            }

            for target in manifest.targets where targetNames.contains(target.name) {
                localSwiftPackageProductLabels[target.name] = BazelLabel(package: packagePath, name: target.name)
            }
            for target in manifest.binaryTargets where targetNames.contains(target.name) {
                localSwiftPackageProductLabels[target.name] = BazelLabel(package: packagePath, name: target.name)
            }
        }
    }

    mutating func indexRemoteSwiftPackages() throws {
        remoteSwiftPackageRepositories = orderedUnique(
            allRemoteSwiftPackages().map { remoteSwiftPackageRepositoryName(for: $0.url) }
        ).sorted()

        let packageDependencyProducts = graph.projects
            .flatMap(\.targets)
            .flatMap(\.dependencies)
            .compactMap { dependency -> String? in
                guard case let .package(product, kind) = dependency, kind == .runtime else {
                    return nil
                }
                return product
            }
        let localPackageDependencyProducts = localSwiftPackageManifests.values
            .flatMap(\.targets)
            .flatMap(\.packageDependencies)

        guard allRemoteSwiftPackages().count == 1,
              let repository = remoteSwiftPackageRepositories.first else {
            if allRemoteSwiftPackages().count > 1 {
                warnings.append("remote Swift package products are not generated because product-to-package mapping is ambiguous")
            }
            return
        }

        for product in orderedUnique(packageDependencyProducts + localPackageDependencyProducts) where localSwiftPackageProductLabels[product] == nil {
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
