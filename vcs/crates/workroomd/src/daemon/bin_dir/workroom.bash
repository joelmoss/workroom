# Workroom's (#695, `bin_dir.rs`), written by the daemon at every start.
#
# The session started bash with this as its ENV, in place of Ghostty's integration
# (WORKROOM_BASH_ENV), which this runs first: it reads bash's startup files itself. Once they have
# run, this puts the daemon's bin folder, WORKROOM_BIN_DIR, first on PATH again: a login profile can
# move it (macOS's path_helper) or set PATH outright (Debian's /etc/profile).
#
# A session that resumes a program (#825, `resume/launch.rs`) names its launch file and the helper
# in WORKROOM_RESUME_FILE and WORKROOM_RESUME_HELPER. Both leave the environment here, before any
# startup file runs, and at the first prompt the helper runs the file's program as this shell's
# first job: ^Z suspends it to this shell, and `fg` brings it back. Here too, before any startup
# file can print a prompt mark or wait (a passphrase), the helper tells the daemon, as this shell,
# that the hook loaded, so the daemon waits for the first prompt.

if [[ "$-" == *i* && -n "${WORKROOM_RESUME_FILE-}" && -n "${WORKROOM_RESUME_HELPER-}" ]]; then
  __workroom_resume_file=$WORKROOM_RESUME_FILE
  __workroom_resume_helper=$WORKROOM_RESUME_HELPER
  "$__workroom_resume_helper" resume-launch --hook-loaded 2>/dev/null
fi
builtin unset WORKROOM_RESUME_FILE WORKROOM_RESUME_HELPER

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

# First in PROMPT_COMMAND, whichever type it is, so the program runs before the first prompt is
# drawn. It takes itself out again: an array's entry, or a string's first command.
# shellcheck disable=SC2128,SC2178
if [[ "$-" == *i* && -n "${__workroom_resume_file-}" ]]; then
  __workroom_resume() {
    if [[ $(builtin declare -p PROMPT_COMMAND 2>/dev/null) == "declare -a"* ]]; then
      PROMPT_COMMAND=("${PROMPT_COMMAND[@]:1}")
    else
      PROMPT_COMMAND=${PROMPT_COMMAND#__workroom_resume;}
      [[ "$PROMPT_COMMAND" != __workroom_resume ]] || PROMPT_COMMAND=
    fi
    builtin unset -f __workroom_resume
    builtin local file=$__workroom_resume_file helper=$__workroom_resume_helper
    builtin unset __workroom_resume_file __workroom_resume_helper
    "$helper" resume-launch "$file"
  }
  if [[ $(builtin declare -p PROMPT_COMMAND 2>/dev/null) == "declare -a"* ]]; then
    PROMPT_COMMAND=(__workroom_resume "${PROMPT_COMMAND[@]}")
  elif [[ -n "${PROMPT_COMMAND-}" ]]; then
    PROMPT_COMMAND="__workroom_resume;$PROMPT_COMMAND"
  else
    PROMPT_COMMAND=__workroom_resume
  fi
fi
