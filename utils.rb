require 'json'
require 'fileutils'

def absolute_path(target)
    folder_path = nil
    for source in target["sources"]
        if source.include?("Sources")
            match = source.match(/.*\/Sources\//)
            folder_path = match ? match[0] : nil
            break
        end
    end
    return folder_path
end

## libraries/BusinessModules/ModuleName
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