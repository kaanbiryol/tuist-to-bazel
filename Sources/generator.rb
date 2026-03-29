def should_skip(target_name, target_type)
    return true if target_type == "unit_tests" || target_type == "ui_tests"
    return true if target_name.include?("Test") || target_name.include?("SwiftLint")
    false
end

def generate_bazel_project(tuist_graph_path, swift_deps_index_path)
    graph = json(tuist_graph_path)

    # projects is an alternating array: [path, project, path, project, ...]
    project_pairs = parse_alternating_array(graph["projects"])

    project_pairs.each do |project_path, project|
        # skip external projects - new format uses "type" instead of "isExternal"
        next if project["type"].key?("external")

        bzl_targets = {}
        # targets is now a Hash {"TargetName" => target_obj}
        project["targets"].each do |target_name, target|
            next if target_name.nil?
            next if should_skip(target_name, target["product"])
            bzl_targets[target_name] = bazel_target(target_name, target)
        end

        tuist_synthesizers = resolve_tuist_synthesizers()
        generate_root_build_file(has_spm_deps: !swift_deps_index_path.nil?)

        local_frameworks = []
        bzl_targets.each do |target_name, target|
            local_frameworks << generate_build_file(bzl_targets, target, swift_deps_index_path, tuist_synthesizers)
        end

        generate_local_framework_build(local_frameworks.compact)
    end
end
