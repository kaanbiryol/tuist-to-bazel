# Skip tests and Swifltint target for now
def should_skip(target)
    target_name = target["name"]
    target_type = target["product"]
    
    if target_type == "unit_tests"
        return true
    end
    if target_name.include?("Test") || target_name.include?("SwiftLint")
        return true
    end
    return false
end

def generate_bazel_project(tuist_graph_path, swift_deps_index_path)
    graph = json(tuist_graph_path)
    swift_package_deps = json(swift_deps_index_path)

    projects = graph["projects"]
    projects.each do |project_path, project|
        ## skip isExternal is true
        next if project["isExternal"]
      
      # ["TargetName": BazelTarget object]
      bzl_targets = {}
      targets = project["targets"]
      targets.each do |target|
          if target["name"].nil?
              next    
          end
          if should_skip(target)
              next
          end
        bzl_target = bazel_target(target)
        bzl_targets[target["name"]] = bzl_target
      end

      tuist_synthesizers = resolve_tuist_synthesizers()
      # todo pass it here
      generate_root_build_file()
  
      # generate BUILD files for each target
      local_frameworks = []
      bzl_targets.each do |target_name, target|
        local_frameworks << generate_build_file(bzl_targets, target, swift_deps_index_path, tuist_synthesizers)
      end
      
      generate_local_framework_build(local_frameworks.compact)
    end
end 
