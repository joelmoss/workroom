# frozen_string_literal: true

require 'open3'
require 'thor'
require 'tty-prompt'
require 'pathname'

module Workroom
  class Commands < Thor
    include Thor::Actions

    IGNORED_JJ_WORKSPACE_NAMES = ['', 'default'].freeze

    attr_reader :name

    class_option :verbose, type: :boolean, aliases: '-v', group: :runtime,
                           desc: 'Print detailed and verbose output'
    add_runtime_options!

    def self.exit_on_failure?
      true
    end

    map 'c' => :create
    map 'd' => :delete
    map %w[ls l] => :list

    desc 'create|c', 'Create a new workroom'
    long_desc <<-DESC, wrap: false
      Create a new workroom at the same level as your main project directory, using JJ workspaces
      if available, otherwise falling back to git worktrees. A random friendly name is
      auto-generated.
    DESC
    def create
      check_not_in_workroom!
      @name = generate_unique_name

      if !options[:pretend]
        if workroom_exists?
          exception = jj? ? JJWorkspaceExistsError : GitWorktreeExistsError
          raise_error exception, "#{vcs_label} '#{name}' already exists!"
        end

        if workroom_path.exist?
          raise_error DirExistsError,
                      "Workroom directory '#{display_path(workroom_path)}' already exists!"
        end
      end

      create_workroom
      update_config(:add)
      run_setup_script

      say
      say "Workroom '#{name}' created successfully at #{display_path(workroom_path)}.", :green

      if @setup_result
        say 'Setup script output:', :blue
        say @setup_result
      end

      say
    end

    desc 'list|l|ls', 'List all workrooms for the current project'
    def list
      project_path, project = config.find_current_project

      # Inside a workroom
      if project && Pathname.pwd.to_s != project_path
        say 'You are already in a workroom.', :yellow
        say "Parent project is at #{display_path(project_path)}"
        return
      end

      # Inside a parent project
      if project
        workrooms = project['workrooms']
        if !workrooms || workrooms.empty?
          say 'No workrooms found for this project.'
          return
        end

        list_workrooms(workrooms, project['vcs'])
        return
      end

      # Neither — list all workrooms grouped by parent
      if config.projects_with_workrooms.empty?
        say 'No workrooms found.'
        return
      end

      config.projects_with_workrooms.each do |path, proj|
        say "#{display_path(path)}:"
        inside path do
          list_workrooms(proj['workrooms'], proj['vcs'])
        end
        say
      end
    end

    desc 'delete|d [NAME]', 'Delete an existing workroom'
    method_option :confirm, type: :string,
                            desc: 'Skip confirmation if value matches the workroom name'
    def delete(name = nil)
      check_not_in_workroom!

      if !name
        interactive_delete
        return
      end

      @name = name
      validate_name!

      if !options[:pretend]
        if !workroom_exists?
          exception = jj? ? JJWorkspaceExistsError : GitWorktreeExistsError
          raise_error exception, "#{vcs_label} '#{name}' does not exist!"
        end

        if options[:confirm]
          if options[:confirm] != name
            raise_error ArgumentError,
                        "--confirm value '#{options[:confirm]}' does not match " \
                        "workroom name '#{name}'."
          end
        elsif !yes?("Are you sure you want to delete workroom '#{name}'?")
          say_error "Aborting. Workroom '#{name}' was not deleted.", :yellow
          return
        end
      end

      delete_by_name(name)
    end

    private

      def run_setup_script
        return if !setup_script.exist?

        parent_dir = Pathname.pwd.to_s
        inside workroom_path do
          run_user_script :setup, setup_script_to_run.to_s, parent_dir
        end
      end

      def setup_script
        @setup_script ||= Pathname.pwd.join('scripts', 'workroom_setup')
      end

      def setup_script_to_run
        setup_script
      end

      def run_teardown_script
        return if !teardown_script.exist?

        parent_dir = Pathname.pwd.to_s
        inside workroom_path do
          run_user_script :teardown, teardown_script_to_run.to_s, parent_dir
        end
      end

      def teardown_script
        @teardown_script ||= Pathname.pwd.join('scripts', 'workroom_teardown')
      end

      def teardown_script_to_run
        teardown_script
      end

      def run_user_script(type, command, parent_dir)
        return if behavior != :invoke

        destination = relative_to_original_destination_root(destination_root, false)

        say_status type, "Running #{command} from #{destination.inspect}"

        return if options[:pretend]

        result, status = Open3.capture2e({ 'WORKROOM_PARENT_DIR' => parent_dir }, command)

        instance_variable_set :"@#{type}_result", result

        return if status.success?

        exception_class = Object.const_get("::Workroom::#{type.to_s.capitalize}Error")

        raise_error exception_class, "#{command} returned a non-zero exit code.\n#{result}"
      end

      def raise_error(exception_class, message)
        message = shell.set_color message, :red if !testing?
        raise exception_class, message
      end

      def config
        @config ||= Config.new
      end

      def workrooms_dir
        @workrooms_dir ||= config.workrooms_dir
      end

      def vcs_name
        "workroom/#{name}"
      end

      def workroom_path
        @workroom_path ||= workrooms_dir.join(name)
      end

      def jj?
        vcs == :jj
      end

      def vcs
        @vcs ||= if Dir.exist?('.jj')
                   say_status :repo, 'Detected Jujutsu'
                   :jj
                 elsif Dir.exist?('.git')
                   say_status :repo, 'Detected Git'
                   :git
                 else
                   say_status :repo, 'No supported VCS detected in this directory.', :red
                   raise_error UnsupportedVCSError, <<~_
                     No supported VCS detected in this directory. Workroom requires either Git or Jujutsu to manage workspaces.
                   _
                 end
      end

      def vcs_label
        jj? ? 'JJ workspace' : 'Git worktree'
      end

      def workroom_exists?
        jj? ? jj_workspace_exists? : git_worktree_exists?
      end

      def jj_workspace_exists?
        jj_workspaces.include?(vcs_name)
      end

      def git_worktree_exists?
        git_worktrees.any? { |path| File.basename(path) == name }
      end

      def jj_workspaces
        @jj_workspaces ||= begin
          out = raw_jj_workspace_list.lines
          out.map { |line| line.split(':').first.strip }.reject do |name|
            IGNORED_JJ_WORKSPACE_NAMES.include?(name)
          end.compact
        end
      end

      def raw_jj_workspace_list
        run 'jj workspace list --color never', capture: true
      end

      def git_worktrees
        @git_worktrees ||= begin
          arr = []
          directory = ''
          raw_git_worktree_list.split("\n").each do |w|
            s = w.split
            directory = s[1] if s[0] == 'worktree'
            arr << directory if s[0] == 'HEAD' && Dir.pwd != directory
          end
          arr
        end
      end

      def raw_git_worktree_list
        run 'git worktree list --porcelain', capture: true
      end

      def validate_name!
        return if /\A[a-zA-Z0-9]([a-zA-Z0-9_-]*[a-zA-Z0-9])?\z/.match?(name)

        say_status :create, name, :red
        raise_error InvalidNameError, <<~_
          Workroom name must be alphanumeric (dashes and underscores allowed), and must not start or end with a dash or underscore.
        _
      end

      # Ensure the command is not being run from within an existing workroom by checking for the
      # presence of the a `.Workroom`.
      def check_not_in_workroom!
        return if !Pathname.pwd.join('.Workroom').exist?

        raise_error InWorkroomError, <<~_
          Looks like you are already in a workroom. Run this command from the root of your main development directory, not from within an existing workroom.
        _
      end

      def interactive_delete
        _, project = config.find_current_project

        if !project || !project['workrooms'] || project['workrooms'].empty?
          say 'No workrooms found for this project.'
          return
        end

        workrooms = project['workrooms']
        prompt = TTY::Prompt.new
        selected = prompt.multi_select(
          'Select workrooms to delete:',
          workrooms.keys
        )

        if selected.empty?
          say_error 'Aborting. No workrooms were selected.', :yellow
          return
        end

        names_list = selected.map { |n| "'#{n}'" }.join(', ')
        if !yes?("Are you sure you want to delete #{selected.size} workroom(s): #{names_list}?")
          say_error 'Aborting. No workrooms were deleted.', :yellow
          return
        end

        selected.each { |n| delete_by_name(n) }
      end

      def delete_by_name(selected_name)
        @name = selected_name
        @workroom_path = nil

        run_teardown_script
        delete_workroom
        cleanup_directory if jj?
        update_config(:remove)

        say "Workroom '#{name}' deleted successfully.", :green

        if !jj?
          say
          say "Note: Git branch '#{vcs_name}' was not deleted."
          say "      Delete manually with `git branch -D #{vcs_name}` if needed."
        end

        return if !@teardown_result

        say
        say 'Teardown script output:', :blue
        say @teardown_result
        say
      end

      def generate_unique_name
        generator = NameGenerator.new
        last_name = nil

        5.times do
          last_name = generator.generate
          if !workroom_exists_for?(last_name) && !workroom_path_for(last_name).exist?
            return last_name
          end
        end

        loop do
          candidate = "#{last_name}-#{rand(10..99)}"
          if !workroom_exists_for?(candidate) && !workroom_path_for(candidate).exist?
            return candidate
          end
        end
      end

      def workroom_exists_for?(candidate)
        @name = candidate
        @workroom_path = nil
        workroom_exists?
      end

      def workroom_path_for(candidate)
        workrooms_dir.join(candidate)
      end

      def create_workroom
        FileUtils.mkdir_p(workrooms_dir) if !workrooms_dir.exist?

        if testing?
          FileUtils.copy('./', workroom_path)
          return
        end

        if jj?
          run "jj workspace add #{workroom_path} --name #{vcs_name}"
        else
          run "git worktree add -b #{vcs_name} #{workroom_path}"
        end
      end

      def delete_workroom
        if testing?
          FileUtils.rm_rf(workroom_path)
          return
        end

        if jj?
          run "jj workspace forget #{vcs_name}"
        else
          run "git worktree remove #{workroom_path} --force"
        end
      end

      def cleanup_directory
        return if !workroom_path.exist?

        remove_dir(workroom_path, verbose:)
      end

      def update_config(action)
        return if options[:pretend]

        if action == :add
          config.add_workroom Pathname.pwd.to_s, name, workroom_path.to_s, vcs
        else
          config.remove_workroom Pathname.pwd.to_s, name
        end
      end

      def run(command, config = {})
        if !config[:force] && testing?
          raise TestError, "Command execution blocked during testing: `#{command}`"
        end

        config[:verbose] = verbose
        config[:capture] = !verbose if !config.key?(:capture)

        super
      end

      def say_status(...)
        super if verbose
      end

      def verbose
        options[:verbose]
      end

      def testing?
        ENV['WORKROOM_TEST'] == '1'
      end

      def display_path(path)
        path.to_s.sub(/\A#{Regexp.escape(Dir.home)}/, '~')
      end

      def list_workrooms(workrooms, vcs)
        rows = workrooms.map do |name, info|
          warnings = workroom_warnings(name, info, vcs)
          row = [shell.set_color(name, :bold), shell.set_color(display_path(info['path']), :black)]
          row << shell.set_color("[#{warnings.join(', ')}]", :yellow) if warnings.any?
          row
        end
        print_table rows, indent: 2
      end

      def workroom_warnings(name, info, stored_vcs)
        warnings = []
        warnings << 'directory not found' if !Dir.exist?(info['path'])
        if !testing?
          vcs_missing = if stored_vcs == 'jj'
                          !jj_workspaces.include?("workroom/#{name}")
                        elsif stored_vcs == 'git'
                          git_worktrees.none? { |path| File.basename(path) == name }
                        end
          warnings << "#{stored_vcs} workspace not found" if vcs_missing
        end
        warnings
      end
  end
end
