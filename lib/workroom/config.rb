# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'rbconfig'

module Workroom
  class Config
    def config_path
      @config_path ||= File.join(config_dir, 'workroom', 'config.json')
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
      data = read
      data[parent_path] ||= { 'vcs' => vcs.to_s, 'workrooms' => {} }
      data[parent_path]['vcs'] = vcs.to_s
      data[parent_path]['workrooms'][name] = { 'path' => workroom_path }
      write data
    end

    def remove_workroom(parent_path, name)
      data = read
      return if !data[parent_path]

      data[parent_path]['workrooms'].delete(name)
      data.delete(parent_path) if data[parent_path]['workrooms'].empty?
      write data
    end

    private

      def config_dir
        case RbConfig::CONFIG['host_os']
        when /darwin/i
          File.expand_path('~/Library/Application Support')
        when /mswin|mingw|cygwin/i
          ENV.fetch('LOCALAPPDATA') { ENV.fetch('APPDATA', File.expand_path('~')) }
        else
          ENV.fetch('XDG_CONFIG_HOME') { File.expand_path('~/.config') }
        end
      end
  end
end
