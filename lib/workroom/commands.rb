# frozen_string_literal: true

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

      say "Workroom '#{name}' created successfully at #{workroom_path}.", :green
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

      say "Workroom '#{name}' deleted successfully.", :green
      return if jj?

      say "Note: Git branch '#{name}' was not deleted."
      say "      Delete manually with `git branch -D #{name}` if needed."
    end

    private

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
                   say_status :repo, 'Detected Jujutsu', :green
                   :jj
                 elsif Dir.exist?('.git')
                   say_status :repo, 'Detected Git', :green
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
        if jj?
          run "jj workspace add #{workroom_path}"
        else
          run "git worktree add -b #{name} #{workroom_path}"
        end
      end

      def delete_workroom
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

      def run(command, config = {})
        raise TestError, "Command execution blocked during testing: `#{command}`" if testing?

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
  end
end
