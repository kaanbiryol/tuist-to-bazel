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

# Generates BazelTarget from the "target" dictionary
def bazel_target(target)
    target_name = target["name"]
    type = target["product"]
    absolute_path = absolute_path(target)
    relative_path = relative_path(absolute_path)
    dependencies = target["dependencies"] || []
    return BazelTarget.new(absolute_path, relative_path, target_name, dependencies, type)
end