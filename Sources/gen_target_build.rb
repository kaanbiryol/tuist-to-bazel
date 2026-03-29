# Generates a BUILD.bazel file for a given target
def generate_build_file(all_targets, bzl_target, external_dependencies, tuist_synthesizers)
    resolved_dependencies = resolve_dependencies(all_targets, bzl_target, external_dependencies)
    all_dependencies = resolved_dependencies[0]
    synth = find_synthesizers_for_target(tuist_synthesizers, bzl_target)

    # For app targets, separate extension deps from library deps
    extension_deps = []
    lib_deps = all_dependencies
    if bzl_target.type == "app"
        extension_deps = all_dependencies.select { |dep| all_targets.any? { |name, t| t.type == "app_extension" && dep.include?(name) } }
        # Extension labels point to Lib, but ios_application extensions need the bundling target
        extension_deps = extension_deps.map { |dep| dep.sub(/Lib$/, "") }
        lib_deps = all_dependencies.reject { |dep| extension_deps.any? { |ext| dep.include?(ext.split(":").last) } }
    end

    build_content = case bzl_target.type
    when "app"
        gen_app_build(bzl_target, lib_deps, extension_deps, synth)
    when "app_extension"
        gen_extension_build(bzl_target, all_dependencies, synth)
    else
        gen_library_build(bzl_target, all_dependencies, synth)
    end

    File.open("#{bzl_target.absolute_path}/BUILD.bazel", 'w') do |file|
      file.write(build_content)
    end
    return resolved_dependencies[1]
end

def gen_library_build(bzl_target, deps, synth)
    <<~BUILD
        load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
        load("@build_bazel_rules_apple//apple:ios.bzl", "ios_build_test")

        package(default_visibility = ["//visibility:public"])

        ios_build_test(
            name = "_#{bzl_target.target_name}",
            minimum_os_version = "17.0",
            targets = [":#{bzl_target.target_name}"]
        )

        swift_library(
            name = "#{bzl_target.target_name}",
            srcs = glob(["**/*.swift"]) + #{format_dependency_labels(synth)},
            data = glob(
                ["Resources/**"],
                exclude = ["**/.DS_Store"],
                allow_empty = True,
            ),
            module_name = "#{bzl_target.target_name}",
            tags = ["manual"],
            deps = #{format_dependency_labels(deps)},
            alwayslink = True
        )
    BUILD
end

def gen_app_build(bzl_target, deps, extension_deps, synth)
    extensions_attr = extension_deps.empty? ? "" : "    extensions = #{format_dependency_labels(extension_deps)},\n"
    <<~BUILD
        load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
        load("@build_bazel_rules_apple//apple:ios.bzl", "ios_application")

        package(default_visibility = ["//visibility:public"])

        ios_application(
            name = "#{bzl_target.target_name}",
            bundle_id = "#{bzl_target.bundle_id}",
        #{extensions_attr}    families = ["iphone", "ipad"],
            infoplists = ["#{bzl_target.infoplist}"],
            minimum_os_version = "17.0",
            deps = [":#{bzl_target.target_name}Lib"],
        )

        swift_library(
            name = "#{bzl_target.target_name}Lib",
            srcs = glob(["**/*.swift"]) + #{format_dependency_labels(synth)},
            data = glob(
                ["Resources/**"],
                exclude = ["**/.DS_Store"],
                allow_empty = True,
            ),
            module_name = "#{bzl_target.target_name}",
            tags = ["manual"],
            deps = #{format_dependency_labels(deps)},
            alwayslink = True
        )
    BUILD
end

def gen_extension_build(bzl_target, deps, synth)
    <<~BUILD
        load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
        load("@build_bazel_rules_apple//apple:ios.bzl", "ios_extension")

        package(default_visibility = ["//visibility:public"])

        ios_extension(
            name = "#{bzl_target.target_name}",
            bundle_id = "#{bzl_target.bundle_id}",
            families = ["iphone", "ipad"],
            infoplists = ["#{bzl_target.infoplist}"],
            minimum_os_version = "17.0",
            deps = [":#{bzl_target.target_name}Lib"],
        )

        swift_library(
            name = "#{bzl_target.target_name}Lib",
            srcs = glob(["**/*.swift"]) + #{format_dependency_labels(synth)},
            data = glob(
                ["Resources/**"],
                exclude = ["**/.DS_Store"],
                allow_empty = True,
            ),
            module_name = "#{bzl_target.target_name}",
            tags = ["manual"],
            deps = #{format_dependency_labels(deps)},
            alwayslink = True
        )
    BUILD
end

def format_dependency_labels(deps)
    deps = deps.sort
    formatted_deps = deps.map { |dep| "        \"#{dep}\"," }.join("\n")
    formatted_deps = "[\n#{formatted_deps}\n    ]"
    return formatted_deps
end

def find_synthesizers_for_target(tuist_synthesizers, bazel_target)
    synth = tuist_synthesizers.select { |synth|
        bazel_target.target_name == synth.target_name
    }
    return synth.map { |synth| synth.label }
end
