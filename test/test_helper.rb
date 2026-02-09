# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require 'workroom'
require 'maxitest/autorun'
require 'mocha/minitest'
require 'minitest/focus'
require 'pathname'
require 'fakefs'
require 'tty-prompt'

ENV['WORKROOM_TEST'] = '1'
ENV['THOR_DEBUG'] = ENV.fetch('WORKROOM_TEST', nil)
SANDBOX_PATH = Pathname.pwd.join('sandbox')
BIN_PATH = Pathname.new(File.expand_path('../bin/workroom', __dir__))

def sandbox(&)
  FakeFS.with_fresh do
    SANDBOX_PATH.mkdir
    Dir.chdir SANDBOX_PATH, &
  end
end

def command(*args)
  Workroom::Commands.start(args)
end

# rubocop:disable Style/EvalWithLocation,Security/Eval,Style/DocumentDynamicEvalDefinition
def capture(stream)
  begin
    stream = stream.to_s
    eval "$#{stream} = StringIO.new"
    yield
    result = eval("$#{stream}").string
  ensure
    eval("$#{stream} = #{stream.upcase}")
  end

  result
end
# rubocop:enable Style/EvalWithLocation,Security/Eval,Style/DocumentDynamicEvalDefinition
