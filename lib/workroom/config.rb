# frozen_string_literal: true

require 'json'
require 'fileutils'
module Workroom
  class Config
    CONFIG_DIR = File.expand_path('~/.config/workroom')
    DEFAULT_WORKROOMS_DIR = '~/workrooms'

    def config_path
      @config_path ||= File.join(CONFIG_DIR, 'config.json')
    end

    def read
      return {} if !File.exist?(config_path)

      JSON.parse(File.read(config_path))
    end

    def write(data)
      dir = File.dirname(config_path)
      FileUtils.mkdir_p(dir)
      File.write(config_path, JSON.pretty_generate(data))
    end

    def add_workroom(parent_path, name, workroom_path, vcs)
      update do |data|
        data[parent_path] ||= { 'vcs' => vcs.to_s, 'workrooms' => {} }
        data[parent_path]['vcs'] = vcs.to_s
        data[parent_path]['workrooms'][name] = { 'path' => workroom_path }
      end
    end

    def remove_workroom(parent_path, name)
      update do |data|
        return if !data[parent_path]

        data[parent_path]['workrooms'].delete(name)
        data.delete(parent_path) if data[parent_path]['workrooms'].empty?
      end
    end

    def workrooms_dir
      Pathname.new(File.expand_path(read['workrooms_dir'] || DEFAULT_WORKROOMS_DIR))
    end

    def workrooms_dir=(path)
      update { |data| data['workrooms_dir'] = path }
    end

    private

      def update
        data = read
        yield data
        write data
      end
  end
end
