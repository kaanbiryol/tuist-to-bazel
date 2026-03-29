class BazelTarget
    attr_accessor :absolute_path, :relative_path, :target_name, :dependencies, :type
    def initialize(absolute_path, relative_path, target_name, dependencies, type)
        @absolute_path = absolute_path
        @relative_path = relative_path
        @target_name = target_name
        @dependencies = dependencies
        @type = type
    end

    def label
        return "//#{relative_path}:#{target_name}"
    end
end

# Generates BazelTarget from the new XcodeGraph format
def bazel_target(target_name, target)
    type = target["product"]
    abs_path = source_directory(target)
    rel_path = abs_path ? relative_path(abs_path) : target_name
    dependencies = target["dependencies"] || []
    return BazelTarget.new(abs_path, rel_path, target_name, dependencies, type)
end