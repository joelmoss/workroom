# frozen_string_literal: true

require 'test_helper'

describe Workroom do
  it 'has a version number' do
    refute_nil Workroom::VERSION
  end

  context 'Config' do
    it 'returns config path under ~/.config' do
      config = Workroom::Config.new
      assert_equal(
        File.expand_path('~/.config/workroom/config.json'),
        config.config_path
      )
    end

    let(:config) do
      c = Workroom::Config.new
      c.stubs(:config_path).returns('/tmp/workroom/config.json')
      c
    end

    it 'reads empty hash when config file does not exist' do
      sandbox do
        assert_equal({}, config.read)
      end
    end

    it 'creates config file and directory if they do not exist' do
      sandbox do
        config.add_workroom('/project', 'foo', '/foo', :jj)
        assert File.exist?('/tmp/workroom/config.json')
      end
    end

    it 'adds a workroom entry' do
      sandbox do
        config.add_workroom('/project', 'foo', '/foo', :jj)
        data = config.read
        assert_equal '/foo', data['/project']['workrooms']['foo']['path']
        assert_equal 'jj', data['/project']['vcs']
      end
    end

    it 'adds multiple workroom entries' do
      sandbox do
        config.add_workroom('/project', 'foo', '/foo', :jj)
        config.add_workroom('/project', 'bar', '/bar', :jj)
        data = config.read
        assert_equal '/foo', data['/project']['workrooms']['foo']['path']
        assert_equal '/bar', data['/project']['workrooms']['bar']['path']
      end
    end

    it 'removes a workroom entry and cleans up empty parent' do
      sandbox do
        config.add_workroom('/project', 'foo', '/foo', :jj)
        config.remove_workroom('/project', 'foo')
        data = config.read
        assert_nil data['/project']
      end
    end

    it 'removes a workroom entry but keeps parent with remaining workrooms' do
      sandbox do
        config.add_workroom('/project', 'foo', '/foo', :jj)
        config.add_workroom('/project', 'bar', '/bar', :jj)
        config.remove_workroom('/project', 'foo')
        data = config.read
        assert_nil data['/project']['workrooms']['foo']
        assert_equal '/bar', data['/project']['workrooms']['bar']['path']
      end
    end

    it 'handles remove for nonexistent parent gracefully' do
      sandbox do
        config.remove_workroom('/nonexistent', 'foo')
        assert_equal({}, config.read)
      end
    end

    it 'returns default workrooms_dir when not configured' do
      sandbox do
        assert_equal Pathname.new(File.expand_path('~/workrooms')), config.workrooms_dir
      end
    end

    it 'returns configured workrooms_dir' do
      sandbox do
        config.workrooms_dir = '/custom/workrooms'
        assert_equal Pathname.new('/custom/workrooms'), config.workrooms_dir
      end
    end

    it 'expands tilde in workrooms_dir' do
      sandbox do
        config.workrooms_dir = '~/my-workrooms'
        assert_equal Pathname.new(File.expand_path('~/my-workrooms')), config.workrooms_dir
      end
    end
  end

  context 'create' do
    it 'errors if not a jj or git repo' do
      Workroom::NameGenerator.any_instance.stubs(:generate).returns('foo')

      sandbox do
        assert_raises Workroom::UnsupportedVCSError do
          command(:create)
        end
      end
    end

    it 'errors if run within a workroom' do
      sandbox do
        FileUtils.touch('.Workroom')

        assert_raises Workroom::InWorkroomError do
          command(:create)
        end
      end
    end

    it 'succeeds' do
      cmd = Workroom::Commands.any_instance
      cmd.stubs(:raw_jj_workspace_list).returns 'default: mk 6ec05f05 (no description set)'
      cmd.stubs(:workrooms_dir).returns(Pathname.new('/workrooms'))
      Workroom::NameGenerator.any_instance.stubs(:generate).returns('foo')

      sandbox do
        FileUtils.mkdir('.jj')

        out = capture(:stdout) { command(:create) }
        assert_match "Workroom 'foo' created successfully at /workrooms/foo.", out
        assert Dir.exist?('/workrooms/foo')
      end
    end

    it 'updates config on create' do
      cmd = Workroom::Commands.any_instance
      cmd.stubs(:raw_jj_workspace_list).returns 'default: mk 6ec05f05 (no description set)'
      cmd.stubs(:workrooms_dir).returns(Pathname.new('/workrooms'))
      Workroom::NameGenerator.any_instance.stubs(:generate).returns('foo')

      sandbox do
        FileUtils.mkdir('.jj')
        config = Workroom::Config.new
        config_path = config.config_path

        capture(:stdout) { command(:create) }

        data = JSON.parse(File.read(config_path))
        parent = Pathname.pwd.to_s
        assert_equal 'jj', data[parent]['vcs']
        assert_equal '/workrooms/foo', data[parent]['workrooms']['foo']['path']
      end
    end

    it 'runs the setup script if it exists' do
      cmd = Workroom::Commands.any_instance
      cmd.stubs(:raw_jj_workspace_list).returns 'default: mk 6ec05f05 (no description set)'
      cmd.stubs(:workrooms_dir).returns(Pathname.new('/workrooms'))
      cmd.stubs(:setup_script_to_run).returns("#{__dir__}/fixtures/setup")
      Workroom::NameGenerator.any_instance.stubs(:generate).returns('foo')

      sandbox do
        FileUtils.mkdir('.jj')
        FileUtils.mkdir_p('scripts')
        FileUtils.touch('scripts/workroom_setup')

        out = capture(:stdout) { command(:create) }
        assert_match 'I succeeded', out
        assert_match "Workroom 'foo' created successfully at /workrooms/foo.\n", out
      end
    end

    it 'errors on failed setup script' do
      cmd = Workroom::Commands.any_instance
      cmd.stubs(:raw_jj_workspace_list).returns 'default: mk 6ec05f05 (no description set)'
      cmd.stubs(:workrooms_dir).returns(Pathname.new('/workrooms'))
      cmd.stubs(:setup_script_to_run).returns("#{__dir__}/fixtures/failed_setup")
      Workroom::NameGenerator.any_instance.stubs(:generate).returns('foo')

      sandbox do
        FileUtils.mkdir('.jj')
        FileUtils.mkdir_p('scripts')
        FileUtils.touch('scripts/workroom_setup')

        err = assert_raises Workroom::SetupError do
          command(:create)
        end
        assert_match 'I failed', err.message
      end
    end

    it 'retries on name collision with existing workspace' do
      Workroom::NameGenerator.any_instance
                             .stubs(:generate)
                             .returns('taken').then.returns('fresh')

      cmd = Workroom::Commands.any_instance
      cmd.stubs(:raw_jj_workspace_list)
         .returns <<~_
           default: mk 6ec05f05 (no description set)
           workroom/taken: qo a41890ed (empty) (no description set)
         _
      cmd.stubs(:workrooms_dir).returns(Pathname.new('/workrooms'))

      sandbox do
        FileUtils.mkdir('.jj')

        out = capture(:stdout) { command(:create) }
        assert_match "Workroom 'fresh' created successfully at /workrooms/fresh.", out
      end
    end

    it 'retries on name collision with existing directory' do
      cmd = Workroom::Commands.any_instance
      cmd.stubs(:raw_jj_workspace_list)
         .returns 'default: mk 6ec05f05 (no description set)'
      cmd.stubs(:workrooms_dir).returns(Pathname.new('/workrooms'))

      Workroom::NameGenerator.any_instance
                             .stubs(:generate)
                             .returns('taken').then.returns('fresh')

      sandbox do
        FileUtils.mkdir('.jj')
        FileUtils.mkdir_p('/workrooms/taken')

        out = capture(:stdout) { command(:create) }
        assert_match "Workroom 'fresh' created successfully at /workrooms/fresh.", out
      end
    end
  end

  context 'list' do
    it 'lists workrooms for the current project' do
      sandbox do
        config = Workroom::Config.new
        FileUtils.mkdir('/foo')
        FileUtils.mkdir('/bar')
        config.add_workroom(Pathname.pwd.to_s, 'foo', '/foo', :jj)
        config.add_workroom(Pathname.pwd.to_s, 'bar', '/bar', :jj)

        out = capture(:stdout) { command(:list) }
        assert_match(%r{^\s+foo\s+/foo$}, out)
        assert_match(%r{^\s+bar\s+/bar$}, out)
      end
    end

    it 'warns when workroom directory does not exist' do
      sandbox do
        config = Workroom::Config.new
        config.add_workroom(Pathname.pwd.to_s, 'foo', '/nonexistent', :jj)

        out = capture(:stdout) { command(:list) }
        assert_match(%r{foo\s+/nonexistent\s+\[directory not found\]}, out)
      end
    end

    it 'does not warn when workroom directory exists' do
      sandbox do
        config = Workroom::Config.new
        FileUtils.mkdir('/myworkroom')
        config.add_workroom(Pathname.pwd.to_s, 'foo', '/myworkroom', :jj)

        out = capture(:stdout) { command(:list) }
        assert_match(%r{^\s+foo\s+/myworkroom$}, out)
        refute_match(/directory not found/, out)
      end
    end

    it 'lists all workrooms grouped by parent from an unknown directory' do
      sandbox do
        config = Workroom::Config.new
        FileUtils.mkdir_p('/other/baz')
        FileUtils.mkdir_p('/another/qux')
        config.add_workroom('/other/project', 'baz', '/other/baz', :git)
        config.add_workroom('/another/project', 'qux', '/another/qux', :jj)

        out = capture(:stdout) { command(:list) }
        assert_match(%r{^/other/project:$}, out)
        assert_match(%r{^\s+baz\s+/other/baz$}, out)
        assert_match(%r{^/another/project:$}, out)
        assert_match(%r{^\s+qux\s+/another/qux$}, out)
      end
    end

    it 'shows message when no workrooms exist anywhere' do
      sandbox do
        out = capture(:stdout) { command(:list) }
        assert_match 'No workrooms found.', out
      end
    end

    it 'details parent project when inside a workroom' do
      sandbox do
        config = Workroom::Config.new
        project_path = Pathname.pwd.to_s
        workroom_path = '/myworkroom'
        FileUtils.mkdir(workroom_path)
        config.add_workroom(project_path, 'myworkroom', workroom_path, :jj)

        Dir.chdir(workroom_path) do
          out = capture(:stdout) { command(:list) }
          assert_match(
            /You are already in a workroom\.\nParent project is at #{Regexp.escape(project_path)}/,
            out
          )
        end
      end
    end
  end

  context 'delete (interactive)' do
    it 'shows message when no workrooms exist' do
      sandbox do
        FileUtils.mkdir('.jj')

        out = capture(:stdout) { command(:delete) }
        assert_match 'No workrooms found for this project.', out
      end
    end

    it 'deletes a single selected workroom' do
      cmd = Workroom::Commands.any_instance
      cmd.stubs(:raw_jj_workspace_list).returns <<~_
        default: mk 6ec05f05 (no description set)
        workroom/foo: mk 6ec05f05 (no description set)
      _
      cmd.stubs(:workrooms_dir).returns(Pathname.new('/workrooms'))

      prompt = mock('prompt')
      TTY::Prompt.stubs(:new).returns(prompt)
      prompt.expects(:multi_select).with(
        'Select workrooms to delete:',
        ['foo']
      ).returns(['foo'])

      Thor::LineEditor.expects(:readline).with(
        "Are you sure you want to delete 1 workroom(s): 'foo'? ",
        { add_to_history: false }
      ).returns('y')

      sandbox do
        FileUtils.mkdir('.jj')
        FileUtils.mkdir_p('/workrooms/foo')

        config = Workroom::Config.new
        config.add_workroom(Pathname.pwd.to_s, 'foo', '/workrooms/foo', :jj)

        out = capture(:stdout) { command(:delete) }
        assert_match "Workroom 'foo' deleted successfully.", out
        refute Dir.exist?('/workrooms/foo')
      end
    end

    it 'deletes multiple selected workrooms' do
      cmd = Workroom::Commands.any_instance
      cmd.stubs(:raw_jj_workspace_list).returns <<~_
        default: mk 6ec05f05 (no description set)
        workroom/foo: mk 6ec05f05 (no description set)
        workroom/bar: mk 6ec05f05 (no description set)
      _
      cmd.stubs(:workrooms_dir).returns(Pathname.new('/workrooms'))

      prompt = mock('prompt')
      TTY::Prompt.stubs(:new).returns(prompt)
      prompt.expects(:multi_select).with(
        'Select workrooms to delete:',
        %w[foo bar]
      ).returns(%w[foo bar])

      Thor::LineEditor.expects(:readline).with(
        "Are you sure you want to delete 2 workroom(s): 'foo', 'bar'? ",
        { add_to_history: false }
      ).returns('y')

      sandbox do
        FileUtils.mkdir('.jj')
        FileUtils.mkdir_p('/workrooms/foo')
        FileUtils.mkdir_p('/workrooms/bar')

        config = Workroom::Config.new
        config.add_workroom(Pathname.pwd.to_s, 'foo', '/workrooms/foo', :jj)
        config.add_workroom(Pathname.pwd.to_s, 'bar', '/workrooms/bar', :jj)

        out = capture(:stdout) { command(:delete) }
        assert_match "Workroom 'foo' deleted successfully.", out
        assert_match "Workroom 'bar' deleted successfully.", out
        refute Dir.exist?('/workrooms/foo')
        refute Dir.exist?('/workrooms/bar')
      end
    end

    it 'aborts when user declines confirmation' do
      cmd = Workroom::Commands.any_instance
      cmd.stubs(:raw_jj_workspace_list).returns <<~_
        default: mk 6ec05f05 (no description set)
        workroom/foo: mk 6ec05f05 (no description set)
      _
      cmd.stubs(:workrooms_dir).returns(Pathname.new('/workrooms'))

      prompt = mock('prompt')
      TTY::Prompt.stubs(:new).returns(prompt)
      prompt.expects(:multi_select).with(
        'Select workrooms to delete:',
        ['foo']
      ).returns(['foo'])

      Thor::LineEditor.expects(:readline).with(
        "Are you sure you want to delete 1 workroom(s): 'foo'? ",
        { add_to_history: false }
      ).returns('n')

      sandbox do
        FileUtils.mkdir('.jj')
        FileUtils.mkdir_p('/workrooms/foo')

        config = Workroom::Config.new
        config.add_workroom(Pathname.pwd.to_s, 'foo', '/workrooms/foo', :jj)

        out = capture(:stderr) { command(:delete) }
        assert_match 'Aborting. No workrooms were deleted.', out
        assert Dir.exist?('/workrooms/foo')
      end
    end

    it 'aborts when no workrooms are selected' do
      cmd = Workroom::Commands.any_instance
      cmd.stubs(:raw_jj_workspace_list).returns <<~_
        default: mk 6ec05f05 (no description set)
        workroom/foo: mk 6ec05f05 (no description set)
      _
      cmd.stubs(:workrooms_dir).returns(Pathname.new('/workrooms'))

      prompt = mock('prompt')
      TTY::Prompt.stubs(:new).returns(prompt)
      prompt.expects(:multi_select).with(
        'Select workrooms to delete:',
        ['foo']
      ).returns([])

      sandbox do
        FileUtils.mkdir('.jj')
        FileUtils.mkdir_p('/workrooms/foo')

        config = Workroom::Config.new
        config.add_workroom(Pathname.pwd.to_s, 'foo', '/workrooms/foo', :jj)

        out = capture(:stderr) { command(:delete) }
        assert_match 'Aborting. No workrooms were selected.', out
        assert Dir.exist?('/workrooms/foo')
      end
    end
  end

  context 'delete' do
    it 'errors on invalid name' do
      assert_raises Workroom::InvalidNameError do
        command(:delete, 'fo.o')
      end
    end

    it 'errors if not a jj or git repo' do
      sandbox do
        assert_raises Workroom::UnsupportedVCSError do
          command(:delete, 'foo')
        end
      end
    end

    it 'errors if jj workspace does not exists' do
      Workroom::Commands.any_instance
                        .stubs(:raw_jj_workspace_list)
                        .returns 'default: mk 6ec05f05 (no description set)'

      sandbox do
        FileUtils.mkdir('.jj')

        assert_raises Workroom::JJWorkspaceExistsError do
          command(:delete, 'foo')
        end
      end
    end

    it 'errors if git worktree does not exists' do
      Workroom::Commands.any_instance
                        .stubs(:raw_git_worktree_list)
                        .returns <<~_
                          worktree /
                          HEAD cbace1f043eee2836c7b8494797dfe49f6985716
                          branch refs/heads/master

                        _

      sandbox do
        FileUtils.mkdir('.git')

        assert_raises Workroom::GitWorktreeExistsError do
          command(:delete, 'foo')
        end
      end
    end

    it 'errors if run within a workroom' do
      sandbox do
        FileUtils.touch('.Workroom')

        assert_raises Workroom::InWorkroomError do
          command(:delete, 'foo')
        end
      end
    end

    it 'succeeds' do
      cmd = Workroom::Commands.any_instance
      cmd.stubs(:raw_jj_workspace_list).returns <<~_
        default: mk 6ec05f05 (no description set)
        workroom/foo: mk 6ec05f05 (no description set)
      _
      cmd.stubs(:say).returns("Workroom 'foo' deleted successfully.")
      cmd.stubs(:workrooms_dir).returns(Pathname.new('/workrooms'))

      Thor::LineEditor.expects(:readline).with(
        "Are you sure you want to delete workroom 'foo'? ", { add_to_history: false }
      ).returns('y')

      sandbox do
        FileUtils.mkdir('.jj')
        FileUtils.mkdir_p('/workrooms/foo')

        command(:delete, 'foo')
        refute Dir.exist?('/workrooms/foo')
      end
    end

    it 'updates config on delete' do
      cmd = Workroom::Commands.any_instance
      cmd.stubs(:raw_jj_workspace_list).returns <<~_
        default: mk 6ec05f05 (no description set)
        workroom/foo: mk 6ec05f05 (no description set)
      _
      cmd.stubs(:say).returns("Workroom 'foo' deleted successfully.")
      cmd.stubs(:workrooms_dir).returns(Pathname.new('/workrooms'))

      Thor::LineEditor.expects(:readline).with(
        "Are you sure you want to delete workroom 'foo'? ", { add_to_history: false }
      ).returns('y')

      sandbox do
        FileUtils.mkdir('.jj')
        FileUtils.mkdir_p('/workrooms/foo')

        # Pre-populate config
        config = Workroom::Config.new
        config.add_workroom(Pathname.pwd.to_s, 'foo', '/workrooms/foo', :jj)

        command(:delete, 'foo')

        data = config.read
        assert_nil data[Pathname.pwd.to_s]
      end
    end

    it '--confirm skips prompt and deletes' do
      cmd = Workroom::Commands.any_instance
      cmd.stubs(:raw_jj_workspace_list).returns <<~_
        default: mk 6ec05f05 (no description set)
        workroom/foo: mk 6ec05f05 (no description set)
      _
      cmd.stubs(:say).returns("Workroom 'foo' deleted successfully.")
      cmd.stubs(:workrooms_dir).returns(Pathname.new('/workrooms'))

      Thor::LineEditor.expects(:readline).never

      sandbox do
        FileUtils.mkdir('.jj')
        FileUtils.mkdir_p('/workrooms/foo')

        command(:delete, 'foo', '--confirm', 'foo')
        refute Dir.exist?('/workrooms/foo')
      end
    end

    it '--confirm with mismatched name raises error' do
      cmd = Workroom::Commands.any_instance
      cmd.stubs(:raw_jj_workspace_list).returns <<~_
        default: mk 6ec05f05 (no description set)
        workroom/foo: mk 6ec05f05 (no description set)
      _
      cmd.stubs(:workrooms_dir).returns(Pathname.new('/workrooms'))

      sandbox do
        FileUtils.mkdir('.jj')
        FileUtils.mkdir_p('/workrooms/foo')

        err = assert_raises ArgumentError do
          command(:delete, 'foo', '--confirm', 'wrong')
        end
        assert_match "--confirm value 'wrong' does not match workroom name 'foo'", err.message
      end
    end

    it '--confirm with matching name updates config' do
      cmd = Workroom::Commands.any_instance
      cmd.stubs(:raw_jj_workspace_list).returns <<~_
        default: mk 6ec05f05 (no description set)
        workroom/foo: mk 6ec05f05 (no description set)
      _
      cmd.stubs(:say).returns("Workroom 'foo' deleted successfully.")
      cmd.stubs(:workrooms_dir).returns(Pathname.new('/workrooms'))

      Thor::LineEditor.expects(:readline).never

      sandbox do
        FileUtils.mkdir('.jj')
        FileUtils.mkdir_p('/workrooms/foo')

        config = Workroom::Config.new
        config.add_workroom(Pathname.pwd.to_s, 'foo', '/workrooms/foo', :jj)

        command(:delete, 'foo', '--confirm', 'foo')

        data = config.read
        assert_nil data[Pathname.pwd.to_s]
      end
    end

    it 'runs the teardown script if it exists' do
      cmd = Workroom::Commands.any_instance
      cmd.stubs(:raw_jj_workspace_list).returns <<~_
        default: mk 6ec05f05 (no description set)
        workroom/foo: mk 6ec05f05 (no description set)
      _
      cmd.stubs(:teardown_script_to_run).returns("#{__dir__}/fixtures/teardown")
      cmd.stubs(:workrooms_dir).returns(Pathname.new('/workrooms'))

      Thor::LineEditor.expects(:readline).with(
        "Are you sure you want to delete workroom 'foo'? ", { add_to_history: false }
      ).returns('y')

      sandbox do
        FileUtils.mkdir('.jj')
        FileUtils.mkdir_p('/workrooms/foo')
        FileUtils.mkdir('/sandbox/scripts')
        FileUtils.touch('/sandbox/scripts/workroom_teardown')

        out = capture(:stdout) { command(:delete, 'foo') }
        assert_match 'I teared down', out
        assert_match "Workroom 'foo' deleted successfully.", out
      end
    end

    it 'errors on failed teardown script' do
      cmd = Workroom::Commands.any_instance
      cmd.stubs(:raw_jj_workspace_list).returns <<~_
        default: mk 6ec05f05 (no description set)
        workroom/foo: mk 6ec05f05 (no description set)
      _
      cmd.stubs(:teardown_script_to_run).returns("#{__dir__}/fixtures/failed_teardown")
      cmd.stubs(:workrooms_dir).returns(Pathname.new('/workrooms'))

      Thor::LineEditor.expects(:readline).with(
        "Are you sure you want to delete workroom 'foo'? ", { add_to_history: false }
      ).returns('y')

      sandbox do
        FileUtils.mkdir('.jj')
        FileUtils.mkdir_p('/workrooms/foo')
        FileUtils.mkdir('/sandbox/scripts')
        FileUtils.touch('/sandbox/scripts/workroom_teardown')

        err = assert_raises Workroom::TeardownError do
          command(:delete, 'foo')
        end
        assert_match 'I failed to tear down', err.message
      end
    end
  end
end
