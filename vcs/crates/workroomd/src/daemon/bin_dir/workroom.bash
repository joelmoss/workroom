# Workroom's (#695, `bin_dir.rs`), written by the daemon at every start.
#
# The session started bash with this as its ENV, in place of Ghostty's integration
# (WORKROOM_BASH_ENV), which this runs first: it reads bash's startup files itself. Once they have
# run, this puts the daemon's bin folder, WORKROOM_BIN_DIR, first on PATH again: a login profile can
# move it (macOS's path_helper) or set PATH outright (Debian's /etc/profile).

if [ -n "${WORKROOM_BASH_ENV-}" ]; then
  __workroom_env=$WORKROOM_BASH_ENV
  builtin unset WORKROOM_BASH_ENV
  builtin source "$__workroom_env"
  builtin unset __workroom_env
fi

if [[ "$-" == *i* && -n "${WORKROOM_BIN_DIR-}" ]]; then
  __workroom_path=":$PATH:"
  while [[ "$__workroom_path" == *":$WORKROOM_BIN_DIR:"* ]]; do
    __workroom_path=${__workroom_path/":$WORKROOM_BIN_DIR:"/:}
  done
  __workroom_path=${__workroom_path#:}
  __workroom_path=${__workroom_path%:}
  builtin export PATH="$WORKROOM_BIN_DIR${__workroom_path:+:$__workroom_path}"
  builtin unset __workroom_path
fi
