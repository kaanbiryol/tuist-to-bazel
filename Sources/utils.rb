require 'json'
require 'fileutils'

# Parses Swift's JSONEncoder encoding of [NonStringKey: Value] dictionaries.
# Swift encodes these as flat alternating arrays: [key1, value1, key2, value2, ...]
# Returns an array of [key, value] pairs.
def parse_alternating_array(raw)
    return raw.map { |k, v| [k, v] } if raw.is_a?(Hash)
    pairs = []
    i = 0
    while i < raw.length
        pairs << [raw[i], raw[i + 1]]
        i += 2
    end
    pairs
end

# Derives the source directory for a target from its source file paths.
# Sources in the new format are [{path: "/abs/path/to/file.swift"}, ...]
def source_directory(target)
    sources = target["sources"] || []
    return nil if sources.empty?
    first_source_path = sources[0]["path"]
    File.dirname(first_source_path)
end

def relative_path(target_path, base_path = Dir.pwd)
    target = Pathname.new(target_path)
    base = Pathname.new(base_path)
    target.relative_path_from(base).to_s
end

def file_exists(file_name, directory = Dir.pwd)
    return File.exist?("#{directory}/#{file_name}")
end

def json(json_file)
    file = File.read(json_file)
    JSON.parse(file)
end