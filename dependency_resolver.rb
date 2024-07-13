# require_relative 'path_ops'
require_relative 'tuist_synthesizer'
require "find"

# Initialize a dictionary to store the external dependencies with the format:
# ["Nuke":"@swiftpkg_nuke//:Nuke"]
def parse_external_dependencies(spm_dependencies)
    dependency_dict = {}
    dependencies = json(spm_dependencies)
    products = dependencies["products"]
    for product in products
        # {"identity"=>"needle", "name"=>"NeedleFoundationTest", "type"=>"library", "label"=>"@swiftpkg_needle//:NeedleFoundationTest"}
        dependency_dict[product["name"]] = product["label"]
    end
    return dependency_dict
end

# Resolve all dependencies for a given target
def resolve_dependencies(all_targets, bazel_target, external_dependencies)
    dependencies = bazel_target.dependencies
    local_frameworks = []
    resolved_dependencies = dependencies.map { |dependency|
        target_label = resolve_target_dependency(all_targets, dependency)
        if target_label
            target_label
        elsif external_label = resolve_external_dependency(dependency, parse_external_dependencies(external_dependencies), bazel_target)
            external_label
        else
            local_framework = resolve_local_framework(dependency)
            next if local_framework.nil?
            local_frameworks << local_framework
            local_framework_label = local_framework[0]
            local_framework_label
        end
    }.compact
    return resolved_dependencies.uniq, local_frameworks
end

def resolve_target_dependency(all_targets, dependency)
    dependency_name = dependency['target'] ? dependency['target']['name'] : nil 
    if dependency_name.nil?
        return nil
    end
    internal_target = all_targets[dependency_name]
    if internal_target
        return internal_target.label
    else
        return nil
    end
end 

def resolve_external_dependency(dependency, external_dependencies_dict, bazel_target)
    dependency_name = dependency["project"] ? dependency["project"]["target"] : nil 
    if dependency_name.nil?
        return nil
    end
    # when tuist graph outputs it replaces _ characters with . in the external repo name  
    # we get com_app_lib_proto-types-swift-stubs isntead of com.app.lib.proto-types-swift-stubs 
    dependency_name = dependency_name.gsub("_", ".")
    
    return external_dependencies_dict[dependency_name]
end 

def resolve_local_framework(dependency)
    xcframework_path = dependency['xcframework'] ? dependency['xcframework']['path'] : nil 
    if not xcframework_path.nil?
        local_framework_dependency_path = xcframework_path.include?("/Tuist/") ? nil : xcframework_path
        if not local_framework_dependency_path.nil?
            relative_path = relative_path(local_framework_dependency_path)
            root_folder_name = relative_path.split("/")[0]
            file_component = File.basename(local_framework_dependency_path, File.extname(local_framework_dependency_path))
            return "//#{root_folder_name}:#{file_component}", File.basename(relative_path)
        end
        return nil
    end
    return nil
end

# Derived/**/TuistBundle+Localization.swift
def resolve_tuist_synthesizers
  root_directory = Dir.pwd
  target_directory = File.join(root_directory, "Derived/Sources")
  synthesizers = []
  Find.find(target_directory) do |path|
    if File.file?(path)
      next unless path.end_with?(".swift")
      relative_path = path.sub(root_directory + '/', '')
      bazel_name = "tuist_synth_#{extract_full_name(relative_path)}"
      target_name = extract_partial_name(relative_path)
      synthesizers << TuistSynthesizer.new(bazel_name, target_name, relative_path)
    end
  end
  return synthesizers
end

def extract_full_name(file_path)
    match = file_path.match(/\/([^\/]+)\.swift$/)
    match ? match[1] : nil
end
  
def extract_partial_name(file_path)
    match = file_path.match(/\+([^\/]+)\.swift$/)
    match ? match[1] : nil
end