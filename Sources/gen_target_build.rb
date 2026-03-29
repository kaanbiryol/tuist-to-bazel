# Generates a BUILD.bazel file for a given target
def generate_build_file(all_targets, bzl_target, external_dependencies, tuist_synthesizers)
    resolved_dependencies = resolve_dependencies(all_targets, bzl_target, external_dependencies)
    all_dependencies = resolved_dependencies[0]
    all_dependencies_string = all_dependencies.nil? ? "[]" : all_dependencies
    synth = find_synthesizers_for_target(tuist_synthesizers, bzl_target)
    build_content = <<~BUILD
        load("@build_bazel_rules_apple//apple:ios.bzl", "ios_framework")
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
            deps = #{format_dependency_labels(all_dependencies)},
            alwayslink = True
        )
    BUILD
   
    File.open("#{bzl_target.absolute_path}/BUILD.bazel", 'w') do |file|
      file.write(build_content)
    end
    return resolved_dependencies[1]
end

def format_dependency_labels(deps)
    deps = deps.sort
    formatted_deps = deps.map { |dep| "        \"#{dep}\"," }.join("\n")
    formatted_deps = "[\n#{formatted_deps}\n    ]"
    return formatted_deps
  end

def find_synthesizers_for_target(tuist_synthesizers, bazel_target)
    synth = tuist_synthesizers.select { |synth| 
        # if synt name is empty or nil, return false        
        bazel_target.target_name == synth.target_name
    }
    return synth.map { |synth| synth.label }
end