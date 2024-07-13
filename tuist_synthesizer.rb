class TuistSynthesizer
  attr_accessor :bazel_name, :target_name, :path

  def initialize(bazel_name, target_name, path)
    @bazel_name = bazel_name
    @target_name = target_name
    @path = path
  end

  def label
    return "//:#{bazel_name}"
  end
end
