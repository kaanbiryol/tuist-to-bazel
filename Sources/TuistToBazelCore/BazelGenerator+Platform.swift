import Foundation

extension BazelGenerator {
    enum ApplePlatform: Hashable {
        case ios
        case macOS
        case tvOS
        case watchOS
        case visionOS

        var dependencyConditionName: String {
            switch self {
            case .ios:
                "ios"
            case .macOS:
                "macos"
            case .tvOS:
                "tvos"
            case .watchOS:
                "watchos"
            case .visionOS:
                "visionos"
            }
        }
    }

    func platform(for target: TuistTarget) -> ApplePlatform {
        Self.resolvePlatform(for: target)
    }

    static func resolvePlatform(for target: TuistTarget) -> ApplePlatform {
        let destinations = Set(target.destinations)
        let iosDestinations: Set<String> = ["iPhone", "iPad", "macWithiPadDesign"]
        if !destinations.isDisjoint(with: iosDestinations) {
            return .ios
        }
        if destinations.contains("appleTv") {
            return .tvOS
        }
        if destinations.contains("appleWatch") {
            return .watchOS
        }
        if destinations.contains("appleVision") {
            return .visionOS
        }
        if destinations.contains("mac"), destinations.isDisjoint(with: iosDestinations) {
            return .macOS
        }
        return .ios
    }

    func staticFrameworkRuleName(for platform: ApplePlatform) -> String {
        switch platform {
        case .ios:
            "ios_static_framework"
        case .macOS:
            "macos_static_framework"
        case .tvOS:
            "tvos_static_framework"
        case .watchOS:
            "watchos_static_framework"
        case .visionOS:
            "visionos_static_framework"
        }
    }

    func minimumOSVersion(for platform: ApplePlatform) -> String {
        switch platform {
        case .ios, .tvOS:
            "17.0"
        case .macOS:
            "14.0"
        case .watchOS:
            "9.0"
        case .visionOS:
            "1.0"
        }
    }

    func familiesAttribute(for platform: ApplePlatform, indent: Int) -> String {
        let prefix = String(repeating: " ", count: indent)
        switch platform {
        case .ios:
            return "\(prefix)families = [\"iphone\", \"ipad\"],\n"
        case .tvOS:
            return "\(prefix)families = [\"tv\"],\n"
        case .watchOS:
            return "\(prefix)families = [\"watch\"],\n"
        case .visionOS:
            return "\(prefix)families = [\"vision\"],\n"
        case .macOS:
            return ""
        }
    }

    func testRunnerName(for platform: ApplePlatform) -> String {
        "_\(testRunnerPlatformName(for: platform))_test_runner"
    }

    func testRunnerRuleName(for platform: ApplePlatform) -> String {
        "\(testRunnerPlatformName(for: platform))_test_runner"
    }

    func testRunnerPlatformName(for platform: ApplePlatform) -> String {
        switch platform {
        case .ios:
            "ios"
        case .macOS:
            "macos"
        case .tvOS:
            "tvos"
        case .watchOS:
            "watchos"
        case .visionOS:
            "visionos"
        }
    }
}
