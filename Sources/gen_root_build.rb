# Generates a BUILD.bazel file for a given target
def generate_root_build_file(has_spm_deps: false)
    tuist_synthesizers = resolve_tuist_synthesizers()
    tuist_synthesizers_string = tuist_synthesizers.nil? ? "" : tuist_synthesizers.map { |synth|
         gen_filegroup(synth)
    }.join("\n")

    spm_loads = has_spm_deps ? <<~LOADS : ""
        load("@bazel_gazelle//:def.bzl", "gazelle", "gazelle_binary")
        load("@rules_swift_package_manager//swiftpkg:defs.bzl", "swift_package_tool")
    LOADS

    spm_rules = has_spm_deps ? <<~RULES : ""
        swift_package_tool(
            name = "update_swift_packages",
            cmd = "update",
            package = "Package.swift",
        )

        gazelle_binary(
            name = "gazelle_bin",
            languages = [
                "@swift_gazelle_plugin//gazelle",
            ],
        )

        gazelle(
            name = "update_build_files",
            data = [
                "@swift_deps_info//:swift_deps_index",
            ],
            extra_args = [
                "-swift_dependency_index=$(location @swift_deps_info//:swift_deps_index)",
            ],
            gazelle = ":gazelle_bin",
        )
    RULES

    build_content = <<~BUILD
        load(
            "@rules_xcodeproj//xcodeproj:defs.bzl",
            "top_level_target",
            "xcschemes",
        )
        load("@rules_xcodeproj//xcodeproj:xcodeproj.bzl", "xcodeproj")

        exports_files(glob(["*.plist"]))
        #{spm_loads}
        _SCHEMES = [
            xcschemes.scheme(
                name = "App",
                run = xcschemes.run(
                    build_targets = ["//App:App"],
                    launch_target = "//App:App",
                ),
            ),
        ]

        xcodeproj(
            name = "xcodeproj",
            project_name = "App",
            scheme_autogeneration_mode = "all",
            xcschemes = _SCHEMES,
            top_level_targets = [
                top_level_target(
                    "//App:App",
                    target_environments = ["simulator"],
                ),
            ],
        )
        #{spm_rules}
        #{tuist_synthesizers_string}
    BUILD

    File.open("#{Dir.pwd}/BUILD.bazel", 'w') do |file|
      file.write(build_content)
    end
end

def gen_filegroup(tuist_synthesizer)
    build_content = <<~BUILD
        filegroup(
            name = "#{tuist_synthesizer.bazel_name}",
            srcs = ["#{tuist_synthesizer.path}"],
            visibility = ["//visibility:public"],
        )
    BUILD
end