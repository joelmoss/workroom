# Workroom's (#695, `bin_dir.rs`), written by the daemon at every start.
#
# fish finds this through XDG_DATA_DIRS, which the session put this folder on
# (WORKROOM_FISH_XDG_DIR); it is taken off again here, so the shell's own children don't see it. At
# the first prompt, once config.fish has run, the daemon's bin folder, WORKROOM_BIN_DIR, is put first
# on PATH again.

if set -q WORKROOM_FISH_XDG_DIR
    set --local --path workroom_xdg_dirs "$XDG_DATA_DIRS"
    set --local workroom_kept
    for workroom_dir in $workroom_xdg_dirs
        if test "$workroom_dir" != "$WORKROOM_FISH_XDG_DIR"
            set --append workroom_kept $workroom_dir
        end
    end
    set --erase workroom_dir
    # A path variable, so it is exported joined by colons, as it came.
    if set -q workroom_kept[1]
        set --global --export --path XDG_DATA_DIRS $workroom_kept
    else
        set --erase --global XDG_DATA_DIRS
    end
    set --erase --global WORKROOM_FISH_XDG_DIR
end

# fish 3.3 and later: no `set --function`. A startup file that erased WORKROOM_BIN_DIR keeps the
# PATH it made: never an empty entry, which would be the current directory.
if status --is-interactive; and test -n "$WORKROOM_BIN_DIR"
    function __workroom_bin_first --on-event fish_prompt
        functions --erase __workroom_bin_first
        if not set -q WORKROOM_BIN_DIR; or test -z "$WORKROOM_BIN_DIR"
            return 0
        end
        set -l rest
        for dir in $PATH
            if test "$dir" != "$WORKROOM_BIN_DIR"
                set -a rest $dir
            end
        end
        set --global --export PATH $WORKROOM_BIN_DIR $rest
    end
end
