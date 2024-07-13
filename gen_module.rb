MODULE_FILE = "MODULE.bazel"

# Generates a module file with the given dependencies
def generate_module
    File.open("#{MODULE_FILE}", 'w') do |file|
      module_content = <<~MODULE                    
        bazel_dep(
            name = "rules_xcodeproj",
            version = "2.3.1",
        )
        bazel_dep(
            name = "apple_support",
            version = "1.11.1",
            repo_name = "build_bazel_apple_support",
        )
        bazel_dep(
            name = "rules_apple",
            version = "3.1.1",
            repo_name = "build_bazel_rules_apple",
        )
        bazel_dep(
            name = "rules_swift",
            version = "1.16.0",
            repo_name = "build_bazel_rules_swift",
        )
        bazel_dep(
            name = "rules_ios",
            version = "3.1.4",
            repo_name = "build_bazel_rules_ios",
        )
        bazel_dep(
            name = "swiftlint",
            version = "0.54.0",
            repo_name = "SwiftLint",
        )
        bazel_dep(name = "gazelle", version = "0.37.0")
        bazel_dep(name = "rules_swift_package_manager", version = "0.34.1")
      MODULE
      file.write(module_content)
    end
  end


