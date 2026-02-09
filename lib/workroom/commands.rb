# frozen_string_literal: true

require 'open3'
require 'thor'

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

    desc 'create NAME', 'Create a new workroom'
    long_desc <<-DESC, wrap: false
      Create a new workroom with the given NAME at the same level as your main project directory,
      using JJ workspaces if available, otherwise falling back to git worktrees.
    DESC
    def create(name)
      @name = name
      check_not_in_workroom!
      validate_name!

      if !options[:pretend]
        if workroom_exists?
          exception = jj? ? JJWorkspaceExistsError : GitWorktreeExistsError
          raise_error exception, "#{vcs_label} '#{name}' already exists!"
        end

        if workroom_path.exist?
          raise_error DirExistsError, "Workroom directory '#{workroom_path}' already exists!"
        end
      end

      create_workroom
      update_config(:add)
      run_setup_script

      say
      say "Workroom '#{name}' created successfully at #{workroom_path}.", :green

      if @setup_result
        say 'Setup script output:', :blue
        say @setup_result
      end

      say
    end

    desc 'list', 'List all workrooms for the current project'
    def list
      config = Config.new
      data = config.read
      project = data[Pathname.pwd.to_s]
      workrooms = project&.dig('workrooms')

      if !workrooms || workrooms.empty?
        say 'No workrooms found for this project.'
        return
      end

      say "Workrooms for #{Pathname.pwd}:\n\n"
      rows = workrooms.map do |name, info|
        warnings = workroom_warnings(name, info, project['vcs'])
        row = [name, info['path']]
        row << shell.set_color("[#{warnings.join(', ')}]", :yellow) if warnings.any?
        row
      end
      print_table(rows, indent: 2)
      say
    end

    desc 'delete NAME', 'Delete an existing workroom'
    def delete(name)
      @name = name
      check_not_in_workroom!
      validate_name!

      if !options[:pretend]
        if !workroom_exists?
          exception = jj? ? JJWorkspaceExistsError : GitWorktreeExistsError
          raise_error exception, "#{vcs_label} '#{name}' does not exist!"
        end

        if !yes?("Are you sure you want to delete workroom '#{name}'?")
          say_error "Aborting. Workroom '#{name}' was not deleted.", :yellow
          return
        end
      end

      delete_workroom
      cleanup_directory if jj?
      update_config(:remove)
      run_teardown_script

      say
      say "Workroom '#{name}' deleted successfully.", :green

      if !jj?
        say
        say "Note: Git branch '#{name}' was not deleted."
        say "      Delete manually with `git branch -D #{name}` if needed."
      end

      if @teardown_result
        say
        say 'Teardown script output:', :blue
        say @teardown_result
      end

      say
    end

    private

      def run_setup_script
        return if !setup_script.exist?

        inside workroom_path do
          run_user_script :setup, setup_script_to_run.to_s
        end
      end

      def setup_script
        @setup_script ||= workroom_path.join('scripts', 'workroom_setup')
      end

      def setup_script_to_run
        setup_script
      end

      def run_teardown_script
        return if !teardown_script.exist?

        run_user_script :teardown, teardown_script_to_run.to_s
      end

      def teardown_script
        @teardown_script ||= Pathname.pwd.join('scripts', 'workroom_teardown')
      end

      def teardown_script_to_run
        teardown_script
      end

      def run_user_script(type, command)
        return if behavior != :invoke

        destination = relative_to_original_destination_root(destination_root, false)

        say_status type, "Running #{command} from #{destination.inspect}"

        return if options[:pretend]

        result, status = Open3.capture2e(command)

        instance_variable_set :"@#{type}_result", result

        return if status.success?

        exception_class = Object.const_get("::Workroom::#{type.to_s.capitalize}Error")

        raise_error exception_class, "#{command} returned a non-zero exit code.\n#{result}"
      end

      def raise_error(exception_class, message)
        message = shell.set_color message, :red if !testing?
        raise exception_class, message
      end

      def workroom_path
        @workroom_path ||= Pathname.pwd.join("../#{name}")
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
                   say_status :repo, 'No supported VCS detected', :red
                   raise_error UnsupportedVCSError, <<~_
                     No supported VCS detected. Workroom requires either Jujutsu or Git to manage workspaces.
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
        jj_workspaces.include?(name)
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

        say_status :create, name, :red
        raise_error InWorkroomError, <<~_
          Looks like you are already in a workroom. Run this command from the root of your main development directory, not from within an existing workroom.
        _
      end

      def create_workroom
        if testing?
          FileUtils.copy('./', workroom_path)
          return
        end

        if jj?
          run "jj workspace add #{workroom_path}"
        else
          run "git worktree add -b #{name} #{workroom_path}"
        end
      end

      def delete_workroom
        if testing?
          FileUtils.rm_rf(workroom_path)
          return
        end

        if jj?
          run "jj workspace forget #{name}"
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

        config = Config.new
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

      def workroom_warnings(name, info, stored_vcs)
        warnings = []
        warnings << 'directory not found' if !Dir.exist?(info['path'])
        if !testing?
          vcs_missing = if stored_vcs == 'jj'
                          !jj_workspaces.include?(name)
                        elsif stored_vcs == 'git'
                          git_worktrees.none? { |path| File.basename(path) == name }
                        end
          warnings << "#{stored_vcs} workspace not found" if vcs_missing
        end
        warnings
      end
  end
end
