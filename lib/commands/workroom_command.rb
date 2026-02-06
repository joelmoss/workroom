# frozen_string_literal: true

require 'rails'
require 'net/http'

module Rails
  class WorkroomCommand < Rails::Command::Base
    include Thor::Actions

    class_option :verbose, type: :boolean, default: false, aliases: :v,
                           desc: 'Print detailed and verbose output'

    def self.source_root
      Rails.root
    end

    desc 'add NAME', <<~DESC
      Description:
        Create a new workroom with the given NAME at the same level as your main project directory,
        using JJ workspaces if available, otherwise falling back to git worktrees. The new workroom
        will be initialized with a copy of .env.local and a symlink to .bundle (if it exists). You
        can then `cd` into the new workroom and run `bin/setup` to get going.

      Note:
        The name will be used as a subdomain for your local development URL, so it should be
        something simple and URL-friendly. For example, if your main project is `london`, and you
        use the name `my-feature`, you'll get a new workroom at `../my-feature` and be able to
        access it at `https://my-feature.ernie.localhost` (assuming your HOST_DOMAIN is set to
        `ernie.localhost`).

    DESC
    def add(name)
      check_not_in_workroom!
      boot_application!

      @name = name
      @workroom_path = Rails.root.join("../#{name}")

      error "#{vcs_label} '#{name}' already exists!" if workroom_exists?
      error 'Workroom directory already exists!' if workroom_path.exist?

      create_workroom
      copy_env_local
      symlink_bundle
      print_success_message
    end

    desc 'delete NAME', 'Delete an existing workroom with the given NAME.'
    def delete(name)
      check_not_in_workroom!
      boot_application!

      @name = name
      @workroom_path = Rails.root.join("../#{name}")

      error "Cannot delete. #{vcs_label} '#{name}' does not exist!" if !workroom_exists?

      remove_workroom
      delete_caddy_route
      cleanup_directory if jj?
      print_delete_message
    end

    private

      attr_reader :name, :workroom_path

      def error(message)
        say_error message, :red
        exit 1
      end

      def check_not_in_workroom!
        return if !ENV.key?('DEFAULT_WORKROOM_PATH')

        say_error 'It looks like you are already in a workroom, ' \
                  'as the $DEFAULT_WORKROOM_PATH is set!', :yellow
        error 'Please run this command from the root of your main development directory, ' \
              'not from within an existing workroom.'
      end

      def jj?
        @jj ||= Rails.root.join('.jj').exist?
      end

      def vcs_type
        jj? ? 'jj' : 'git worktree'
      end

      def vcs_label
        jj? ? 'JJ workspace' : 'Git worktree'
      end

      def project_name
        ENV.fetch('PROJECT_NAME').downcase
      end

      def host_domain
        ENV.fetch 'HOST_DOMAIN'
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
        @jj_workspaces ||= `jj workspace list`.lines.map { |line| line.split(':').first.strip }
      end

      def git_worktrees
        @git_worktrees ||= `git worktree list --porcelain`.scan(/worktree (.+)/).flatten
      end

      def create_workroom
        if jj?
          run("jj workspace add --quiet #{workroom_path}", abort_on_failure: true, verbose:)
        else
          run("git worktree add -b #{name} #{workroom_path}", abort_on_failure: true, verbose:)
        end
      end

      def remove_workroom
        if jj?
          run("jj workspace forget #{name}", abort_on_failure: true, verbose:)
        else
          run("git worktree remove #{workroom_path} --force", abort_on_failure: true, verbose:)
        end
      end

      def cleanup_directory
        return if !workroom_path.exist?

        remove_dir(workroom_path, verbose:)
      end

      def copy_env_local
        local_env_path = Rails.root.join('.env.local')
        workroom_env_path = workroom_path.join('.env.local')

        workroom_env_content = <<~ENV
          DEFAULT_WORKROOM_PATH=#{Rails.root}
          PROJECT_NAME=#{name}-#{project_name}
          HOST_DOMAIN=#{name}-#{host_domain}
        ENV

        if local_env_path.exist?
          create_file(workroom_env_path, "#{workroom_env_content}\n#{local_env_path.read}",
                      verbose:)
        else
          say_error '.env.local not found.', :yellow
          create_file(workroom_env_path, workroom_env_content, verbose:)
          if verbose
            say '  Created a fresh .env.local for you. Check out .env.example to get started.',
                :yellow
          end
        end
      end

      def symlink_bundle
        return if !(bundle_path = Rails.root.join('.bundle')).exist?

        create_link(workroom_path.join('.bundle'), bundle_path, verbose:)
      end

      def delete_caddy_route
        caddy_host = 'localhost'
        caddy_port = 2019
        route_id = "#{name}-#{project_name}"

        uri = URI("http://#{caddy_host}:#{caddy_port}/id/#{route_id}")

        begin
          response = Net::HTTP.get_response(uri)
          if !response.is_a?(Net::HTTPSuccess)
            say "No Caddy route found for '#{route_id}', skipping...", :yellow if verbose
            return
          end

          http = Net::HTTP.new(caddy_host, caddy_port)
          request = Net::HTTP::Delete.new("/id/#{route_id}")
          response = http.request(request)

          if response.is_a?(Net::HTTPSuccess)
            say "Caddy route for '#{route_id}' deleted.", :green if verbose
          else
            say_error "Failed to delete Caddy route: #{response.body}", :yellow
          end
        rescue Errno::ECONNREFUSED
          say 'Caddy admin API not available, skipping route deletion.', :yellow
        end
      end

      def print_success_message
        url = "https://#{name}.#{host_domain}"

        say '' if verbose
        say "Workroom '#{name}' created successfully at #{workroom_path}.", :green
        say "You can now `cd #{workroom_path}` and run `bin/setup` to get started."
        say "Then start rails with `bin/rails s` and open #{url} in your browser."
      end

      def print_delete_message
        say '' if verbose
        say "Workroom '#{name}' deleted successfully.", :green
        return if jj?

        say "Note: Branch '#{name}' was not deleted."
        say "      Delete manually with `git branch -D #{name}` if needed."
      end

      def verbose = options[:verbose]
  end
end
