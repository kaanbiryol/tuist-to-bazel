# Deprecated, use gen_module.rb instead

def generate_workspace
    File.open('WORKSPACE', 'w') do |file|
      workspace_content = <<~WORKSPACE
          load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")
  
          http_archive(
              name = "rules_xcodeproj",
              sha256 = "f5c1f4bea9f00732ef9d54d333d9819d574de7020dbd9d081074232b93c10b2c",
              url = "https://github.com/MobileNativeFoundation/rules_xcodeproj/releases/download/1.13.0/release.tar.gz",
          )
          
          load(
              "@rules_xcodeproj//xcodeproj:repositories.bzl",
              "xcodeproj_rules_dependencies",
          )
          
          xcodeproj_rules_dependencies()
          
          load("@bazel_features//:deps.bzl", "bazel_features_deps")
          
          bazel_features_deps()
          
          load(
              "@build_bazel_rules_apple//apple:repositories.bzl",
              "apple_rules_dependencies",
          )
          
          apple_rules_dependencies()
          
          load(
              "@build_bazel_rules_swift//swift:repositories.bzl",
              "swift_rules_dependencies",
          )
          
          swift_rules_dependencies()
          
          load(
              "@build_bazel_rules_swift//swift:extras.bzl",
              "swift_rules_extra_dependencies",
          )
          
          swift_rules_extra_dependencies()
          
          load(
              "@build_bazel_apple_support//lib:repositories.bzl",
              "apple_support_dependencies",
          )
          
          apple_support_dependencies()
      WORKSPACE
      file.write(workspace_content)
    end
  end