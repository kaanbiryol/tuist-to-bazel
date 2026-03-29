MODULE_FILE = "MODULE.bazel"

# Generates a module file with the given dependencies
def generate_module
    File.open("#{MODULE_FILE}", 'w') do |file|
      module_content = <<~MODULE
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
        bazel_dep(
            name = "rules_ios",
            version = "6.0.1",
            repo_name = "build_bazel_rules_ios",
        )
        bazel_dep(
            name = "swiftlint",
            version = "0.63.2",
            repo_name = "SwiftLint",
        )
        bazel_dep(name = "gazelle", version = "0.48.0")
        bazel_dep(name = "rules_swift_package_manager", version = "1.13.0")
      MODULE
      file.write(module_content)
    end
  end


