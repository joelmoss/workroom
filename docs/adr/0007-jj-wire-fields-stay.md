# The jj-era wire fields stay on the daemon protocol until skew is covered

After Jujutsu support was removed (#266), the fields `shared_root`, `barrier_root`, `backend`, `Commit.change_id`, `is_working_copy`, `is_root`, `change_offset`, `divergent_siblings` and `RefKind::Ancestor` stayed on the workroomd wire, accepted and ignored (except that `backend` must be `git`). `Request` and `ExecRequest` use `deny_unknown_fields`, older apps decode the `Commit` fields as non-optional, and a host's daemon can be newer than the app talking to it. They are pruned once a protocol gate or a stable hand-off covers app and daemon skew.

Source: [`vcs/crates/workroomd/src/vcs.rs`](../../vcs/crates/workroomd/src/vcs.rs) (the comment on the ignored request fields), [`vcs/crates/wr-vcs-model/src/lib.rs`](../../vcs/crates/wr-vcs-model/src/lib.rs), the open `TODOS.md` entry "Remove the jj-era wire fields".
