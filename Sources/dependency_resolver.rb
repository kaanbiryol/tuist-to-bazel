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
    external_deps_dict = external_dependencies ? parse_external_dependencies(external_dependencies) : {}
    resolved_dependencies = dependencies.map { |dependency|
        if dependency.key?("target")
            resolve_target_dependency(all_targets, dependency["target"])
        elsif dependency.key?("package")
            resolve_package_dependency(dependency["package"], external_deps_dict)
        elsif dependency.key?("xcframework")
            local_framework = resolve_xcframework_dependency(dependency["xcframework"])
            next if local_framework.nil?
            local_frameworks << local_framework
            local_framework[0]
        else
            # skip sdk, framework, library, bundle, macro
            nil
        end
    }.compact
    return resolved_dependencies.uniq, local_frameworks
end

def resolve_target_dependency(all_targets, target_dep)
    dep_name = target_dep["name"]
    internal_target = all_targets[dep_name]
    internal_target ? internal_target.label : nil
end

def resolve_package_dependency(package_dep, external_deps_dict)
    product_name = package_dep["product"]
    return nil if product_name.nil?
    external_deps_dict[product_name]
end

def resolve_xcframework_dependency(xcf_dep)
    xcf_path = xcf_dep["path"]
    return nil if xcf_path.nil?
    return nil if xcf_path.include?("/Tuist/")
    rel = relative_path(xcf_path)
    root_folder_name = rel.split("/")[0]
    file_component = File.basename(xcf_path, File.extname(xcf_path))
    return "//#{root_folder_name}:#{file_component}", File.basename(rel)
end

# Derived/**/TuistBundle+Localization.swift
def resolve_tuist_synthesizers
  root_directory = Dir.pwd
  target_directory = File.join(root_directory, "Derived/Sources")
  synthesizers = []
  return synthesizers unless Dir.exist?(target_directory)
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