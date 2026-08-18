import Foundation

extension BazelGenerator {
    mutating func infoplistsAttribute(_ target: TuistTarget, packagePath: String, indent: Int) -> String {
        guard let relative = infoPlistRelativePath(target, packagePath: packagePath) else {
            return ""
        }
        return "\(String(repeating: " ", count: indent))infoplists = [\(Starlark.quote(relative))],\n"
    }

    mutating func infoPlistRelativePath(_ target: TuistTarget, packagePath: String) -> String? {
        guard let infoPlistPath = target.infoPlistPath,
              let originalRelative = try? paths.pathRelativeToPackage(infoPlistPath, packagePath: packagePath) else {
            return generatedDefaultInfoPlistRelativePath(for: target, packagePath: packagePath)
        }

        guard let original = try? String(contentsOfFile: infoPlistPath, encoding: .utf8) else {
            return originalRelative
        }

        let sanitized = substitutionMap(for: target).reduce(original) { content, replacement in
            content.replacingOccurrences(of: replacement.key, with: replacement.value)
        }
        guard sanitized != original else {
            return originalRelative
        }

        let generatedRelative = ".bazel/InfoPlists/\(target.name)-Info.plist"
        let generatedOutputPath = packagePath.isEmpty ? generatedRelative : "\(packagePath)/\(generatedRelative)"
        generatedFiles[generatedOutputPath] = sanitized
        warnings.append("generated sanitized Info.plist for \(target.name) at \(generatedOutputPath)")
        return generatedRelative
    }

    mutating func generatedDefaultInfoPlistRelativePath(for target: TuistTarget, packagePath: String) -> String? {
        guard supportsGeneratedDefaultInfoPlist(target.product) else {
            return nil
        }

        let generatedRelative = ".bazel/InfoPlists/\(target.name)-Info.plist"
        let generatedOutputPath = packagePath.isEmpty ? generatedRelative : "\(packagePath)/\(generatedRelative)"
        if generatedFiles[generatedOutputPath] == nil {
            let dictionary = defaultInfoPlistDictionary(for: target)
            guard let data = try? PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0),
                  let content = String(data: data, encoding: .utf8) else {
                warnings.append("failed to generate default Info.plist for \(target.name)")
                return nil
            }
            generatedFiles[generatedOutputPath] = content
            warnings.append("generated default Info.plist for \(target.name) at \(generatedOutputPath)")
        }
        return generatedRelative
    }

    func supportsGeneratedDefaultInfoPlist(_ product: ProductType) -> Bool {
        switch product {
        case .app, .appExtension, .framework:
            true
        case .staticFramework, .staticLibrary, .dynamicLibrary, .macro, .bundle, .unitTests, .uiTests, .unsupported:
            false
        }
    }

    func defaultInfoPlistDictionary(for target: TuistTarget) -> [String: Any] {
        var dictionary: [String: Any] = [
            "CFBundleDevelopmentRegion": "en",
            "CFBundleExecutable": target.productName,
            "CFBundleIdentifier": target.bundleId ?? defaultBundleId(for: target),
            "CFBundleName": target.productName,
            "CFBundlePackageType": packageType(for: target.product),
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1.0",
        ]
        let substitutions = substitutionMap(for: target)
        for (key, value) in target.infoPlistEntries {
            dictionary[key] = propertyListObject(for: value, substitutions: substitutions)
        }
        if let host = extensionHostApp(for: target) {
            let hostVersions = versionInfoPlistValues(for: host)
            if target.infoPlistEntries["CFBundleVersion"] == nil {
                dictionary["CFBundleVersion"] = hostVersions.bundleVersion
            }
            if target.infoPlistEntries["CFBundleShortVersionString"] == nil {
                dictionary["CFBundleShortVersionString"] = hostVersions.shortVersion
            }
        }
        return dictionary
    }

    func versionInfoPlistValues(for target: TuistTarget) -> (bundleVersion: Any, shortVersion: Any) {
        let substitutions = substitutionMap(for: target)
        let fileVersions = infoPlistFileVersionValues(for: target, substitutions: substitutions)
        let bundleVersion = target.infoPlistEntries["CFBundleVersion"].map {
            propertyListObject(for: $0, substitutions: substitutions)
        } ?? fileVersions.bundleVersion ?? "1.0"
        let shortVersion = target.infoPlistEntries["CFBundleShortVersionString"].map {
            propertyListObject(for: $0, substitutions: substitutions)
        } ?? fileVersions.shortVersion ?? "1.0"
        return (bundleVersion, shortVersion)
    }

    func infoPlistFileVersionValues(
        for target: TuistTarget,
        substitutions: [String: String]
    ) -> (bundleVersion: Any?, shortVersion: Any?) {
        guard let infoPlistPath = target.infoPlistPath,
              let data = try? Data(contentsOf: URL(fileURLWithPath: infoPlistPath)),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = plist as? [String: Any] else {
            return (nil, nil)
        }

        return (
            plistVersionValue(dictionary["CFBundleVersion"], substitutions: substitutions),
            plistVersionValue(dictionary["CFBundleShortVersionString"], substitutions: substitutions)
        )
    }

    func plistVersionValue(_ value: Any?, substitutions: [String: String]) -> Any? {
        guard let value else {
            return nil
        }
        if let string = value as? String {
            return substitutions.reduce(string) { content, replacement in
                content.replacingOccurrences(of: replacement.key, with: replacement.value)
            }
        }
        return value
    }

    func extensionHostApp(for target: TuistTarget) -> TuistTarget? {
        guard isExtensionProduct(target.product) else {
            return nil
        }
        let identity = targetIdentity(target)
        let hostApps = graph.projects.flatMap(\.targets)
            .filter { $0.product == .app }

        return hostApps
            .sorted { $0.name < $1.name }
            .first { app in
                app.dependencies.contains { dependency in
                    resolveTargetDependency(dependency).map(targetIdentity) == identity
                }
            } ?? hostApps.filter { app in
                let appBundleId = app.bundleId ?? defaultBundleId(for: app)
                let extensionBundleId = target.bundleId ?? defaultBundleId(for: target)
                return extensionBundleId.hasPrefix("\(appBundleId).")
            }
            .sorted { left, right in
                let leftBundleId = left.bundleId ?? defaultBundleId(for: left)
                let rightBundleId = right.bundleId ?? defaultBundleId(for: right)
                if leftBundleId.count != rightBundleId.count {
                    return leftBundleId.count > rightBundleId.count
                }
                return left.name < right.name
            }
            .first
    }

    func packageType(for product: ProductType) -> String {
        switch product {
        case .app:
            "APPL"
        case .framework:
            "FMWK"
        default:
            "XPC!"
        }
    }

    func propertyListObject(for value: PlistValue, substitutions: [String: String]) -> Any {
        switch value {
        case let .string(string):
            substitutions.reduce(string) { content, replacement in
                content.replacingOccurrences(of: replacement.key, with: replacement.value)
            }
        case let .bool(bool):
            bool
        case let .number(number):
            number.rounded() == number ? Int(number) : number
        case let .array(values):
            values.map { propertyListObject(for: $0, substitutions: substitutions) }
        case let .dictionary(values):
            values.reduce(into: [String: Any]()) { result, element in
                result[element.key] = propertyListObject(for: element.value, substitutions: substitutions)
            }
        }
    }

    func substitutionMap(for target: TuistTarget) -> [String: String] {
        [
            "$(CURRENT_PROJECT_VERSION)": "1.0",
            "$(MARKETING_VERSION)": "1.0",
            "$(DEVELOPMENT_LANGUAGE)": "en",
            "$(EXECUTABLE_NAME)": target.productName,
            "$(PRODUCT_BUNDLE_IDENTIFIER)": target.bundleId ?? defaultBundleId(for: target),
            "$(PRODUCT_MODULE_NAME)": sanitizedModuleName(target.productName),
            "$(PRODUCT_NAME)": target.productName,
            "$(TARGET_NAME)": target.name,
        ]
    }

    func defaultBundleId(for target: TuistTarget) -> String {
        BazelDependencyResolver.defaultBundleId(for: target)
    }
}
