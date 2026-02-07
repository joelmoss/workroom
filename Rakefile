# frozen_string_literal: true

require 'bundler/setup'
require 'bundler/gem_tasks'
require 'minitest/test_task'

Minitest::TestTask.create

require 'rubocop/rake_task'

RuboCop::RakeTask.new

task default: %i[test rubocop]
