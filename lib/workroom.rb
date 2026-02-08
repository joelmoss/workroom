# frozen_string_literal: true

require 'zeitwerk'
loader = Zeitwerk::Loader.for_gem
loader.setup

require 'thor'

module Workroom
  class Error < Thor::Error; end
  class TestError < Thor::Error; end
  class InvalidNameError < Error; end
  class InWorkroomError < Error; end
  class DirExistsError < Error; end
  class UnsupportedVCSError < Error; end
  class JJWorkspaceExistsError < Error; end
  class GitWorktreeExistsError < Error; end
  class SetupError < Error; end
  class TeardownError < Error; end
end
