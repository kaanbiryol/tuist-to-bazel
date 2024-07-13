# Generates a BUILD.bazel file for a given target
def generate_root_build_file()
    tuist_synthesizers = resolve_tuist_synthesizers()
    tuist_synthesizers_string = tuist_synthesizers.nil? ? "" : tuist_synthesizers.map { |synth|
         gen_filegroup(synth) 
    }.join("\n")

    build_content = <<~BUILD
        load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
        load("@gazelle//:def.bzl", "gazelle", "gazelle_binary")
        load("@rules_swift_package_manager//swiftpkg:defs.bzl", "swift_update_packages")
        load(
            "@rules_xcodeproj//xcodeproj:defs.bzl",
            "top_level_target",
            "xcode_schemes",
            "xcodeproj",
        )
        load(
        "@build_bazel_rules_apple//apple:apple.bzl",
        "apple_static_xcframework_import",
        )
        
        _SCHEMES = [
            xcode_schemes.scheme(
                name = "App",
                build_action = xcode_schemes.build_action(
                    targets = ["//apps/App/Sources_App"],
                ),
                launch_action = xcode_schemes.launch_action(
                    "//apps/App/Sources:_App",
                ),
                # test_action = xcode_schemes.test_action(
                #     [
                #     ],
                # ),
            ),
        ]

        xcodeproj(
            name = "xcodeproj",
            build_mode = "bazel",
            # generation_mode = select({
            #     "//build_tools/settings_rules_xcodeproj:bwb": "incremental",
            #     "//build_tools/settings_rules_xcodeproj:bwx": "legacy",
            #     "//conditions:default": "legacy",
            # }),
            # post_build = POST_BUILD_CONFIG,
            project_name = "App",
            scheme_autogeneration_mode = "all",
            schemes = _SCHEMES,
            top_level_targets = [
                top_level_target(
                    "//apps/App/Sources:_App",
                    target_environments = ["simulator"],
                ),
            ],
            # xcode_configurations = {
            #     "Debug": {
            #         "//command_line_option:compilation_mode": "dbg",
            #     },
            #     "Release": {
            #         "//command_line_option:compilation_mode": "opt",
            #     },
            # },
        )
        
        gazelle_binary(
            name = "gazelle_bin",
            languages = [
                "@rules_swift_package_manager//gazelle",
            ],
        )
        
        swift_update_packages(
            name = "swift_update_pkgs",
            gazelle = ":gazelle_bin",
            generate_swift_deps_for_workspace = False,
            update_bzlmod_stanzas = True,
            update_bzlmod_use_repo_names = True
        )
        
        gazelle(
            name = "update_build_files",
            gazelle = ":gazelle_bin",
        )

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