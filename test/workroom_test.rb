# frozen_string_literal: true

require 'test_helper'

describe Workroom do
  it 'has a version number' do
    refute_nil Workroom::VERSION
  end

  context 'create' do
    it 'errors on invalid name' do
      assert_raises Workroom::InvalidNameError do
        command(:create, 'fo.o')
      end
    end

    it 'errors if not a jj or git repo' do
      sandbox do
        assert_raises Workroom::UnsupportedVCSError do
          command(:create, 'foo')
        end
      end
    end

    it 'errors if jj workspace already exists' do
      Workroom::Commands.any_instance
                        .stubs(:raw_jj_workspace_list)
                        .returns <<~_
                          default: mk 6ec05f05 (no description set)
                          foo: qo a41890ed (empty) (no description set)
                        _

      sandbox do
        FileUtils.mkdir('.jj')

        assert_raises Workroom::JJWorkspaceExistsError do
          command(:create, 'foo')
        end
      end
    end

    it 'errors if git worktree already exists' do
      Workroom::Commands.any_instance
                        .stubs(:raw_git_worktree_list)
                        .returns <<~_
                          worktree /
                          HEAD cbace1f043eee2836c7b8494797dfe49f6985716
                          branch refs/heads/master

                          worktree /foo
                          HEAD cbace1f043eee2836c7b8494797dfe49f6985716
                          branch refs/heads/foo

                        _

      sandbox do
        FileUtils.mkdir('.git')

        assert_raises Workroom::GitWorktreeExistsError do
          command(:create, 'foo')
        end
      end
    end

    it 'errors if run within a workroom' do
      sandbox do
        FileUtils.touch('.Workroom')

        assert_raises Workroom::InWorkroomError do
          command(:create, 'foo')
        end
      end
    end

    it 'errors if workroom path already exists' do
      Workroom::Commands.any_instance
                        .stubs(:raw_jj_workspace_list)
                        .returns <<~_
                          default: mk 6ec05f05 (no description set)
                        _

      sandbox do
        FileUtils.mkdir('.jj')
        FileUtils.mkdir('../foo')

        assert_raises Workroom::DirExistsError do
          command(:create, 'foo')
        end
      end
    end

    it 'succeeds' do
      cmd = Workroom::Commands.any_instance
      cmd.stubs(:raw_jj_workspace_list).returns 'default: mk 6ec05f05 (no description set)'
      cmd.stubs(:create_workroom)

      sandbox do
        FileUtils.mkdir('.jj')

        assert_equal "Workroom 'foo' created successfully at /foo.\n", capture(:stdout) {
          command(:create, 'foo')
        }
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
        foo: mk 6ec05f05 (no description set)
      _
      cmd.stubs(:delete_workroom)
      cmd.stubs(:say).returns("Workroom 'foo' deleted successfully.")

      Thor::LineEditor.expects(:readline).with(
        "Are you sure you want to delete workroom 'foo'? ", { add_to_history: false }
      ).returns('y')

      sandbox do
        FileUtils.mkdir('.jj')
        FileUtils.mkdir('../foo')

        command(:delete, 'foo')
        refute Dir.exist?('../foo')
      end
    end
  end
end
