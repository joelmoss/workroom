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

    # Find the project for the current directory. If pwd is a project in the config, return it
    # directly. Otherwise, check if pwd is a workroom path under any project.
    def find_current_project
      data = read
      pwd = Pathname.pwd.to_s
      return [pwd, data[pwd]] if data.key?(pwd)

      data.each do |project_path, project|
        workrooms = project['workrooms'] || {}
        return [project_path, project] if workrooms.any? { |_, info| info['path'] == pwd }
      end

      [pwd, nil]
    end

    def projects_with_workrooms
      @projects_with_workrooms ||= read.select { |_, p| p['workrooms']&.any? }
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
