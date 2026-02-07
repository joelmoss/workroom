# frozen_string_literal: true

require_relative 'lib/workroom/version'

Gem::Specification.new do |spec|
  spec.name        = 'workroom'
  spec.version     = Workroom::VERSION
  spec.authors     = ['Joel Moss']
  spec.email       = ['joel@developwithstyle.com']
  spec.homepage    = 'https://github.com/joelmoss/workroom'
  spec.summary     = 'Manage development workrooms'
  spec.description = 'Create and manage local development workrooms using JJ workspaces or git worktrees' # rubocop:disable Layout/LineLength
  spec.license     = 'MIT'
  spec.required_ruby_version = '>= 3.1.0'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = spec.homepage
  spec.metadata['changelog_uri'] = spec.homepage
  spec.metadata['rubygems_mfa_required'] = 'true'

  spec.executables = %w[workroom]

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir['lib/**/*', 'bin/workroom', 'MIT-LICENSE', 'README.md']
  end

  spec.require_paths = ['lib']

  spec.add_dependency 'thor', '~> 1.5'
  spec.add_dependency 'zeitwerk', '~> 2.7'
end
