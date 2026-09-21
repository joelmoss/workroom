"""OQ19 candidate grid (the values analyze.py tunes over) and the amendment record. FROZEN with labels.py,
gates.py and boundary.md: record.py refuses to record against a grid that differs from the tag. Moved out of
analyze.py after the independent review (T9) noted the amended grid lived outside the preflight guard."""

import gates

CPU_GRID = (0.05, 0.20)            # cores of non-excluded process CPU that count as activity
PTY_RATE_GRID = (30.0, 200.0)      # pty output bytes/s over PTY_WINDOW_S (tmux's clock is ~10, a spinner ~200)
PTY_WINDOW_S = 5.0                 # amendment 1: was 10 (see the note below)
NET_GRID = (None, 500.0)           # eth0 rx+tx bytes/s that count as activity (None = signal not used)
NET_WINDOW_S = 3.0                 # amendment 1: net is a rate over this window, like pty, not per tick
COMPRESSION = gates.WINDOW_GRID_COMPRESSED_S[0] / gates.WINDOW_GRID_S[0]  # a compressed run scales the policy's grace too
WAIT_RULES = ("agnostic", "tty-aware")
SOCKET_AGE_GRID = (None, 30.0)     # an ESTAB socket counts only if its last send/receive is this recent (S6b)
GRACE_GRID = (0.0, 10.0, 30.0)     # seconds after the last pty input that still count as activity (S5); 10 = amendment 1

# POST-HOC AMENDMENT 1 (2026-09-20, owner-approved; see gates.py for the gate half). Made after the
# pre-registered tuning result (commit a8246fb3, results/tuning-preregistered.md: no winner). Grid changes:
# GRACE_GRID gained 10 s, because (0, 30) bracketed the passing range for scenario 14 (0 never sees a
# keystroke's echo, 30 stacks on the window past the time-to-idle allowance); the net signal became a rate
# over NET_WINDOW_S = 3 s, because per-tick bytes at 1 s cadence let the box's ~800 B startup burst vote BUSY
# while scenario 9's steady ~750 B/s traffic needs the signal (a 10 s window averaged the burst away but
# delayed 9's onset past the 3 s allowance; 3 s does both); PTY_WINDOW_S went from 10 to 5 s, because vim's
# 2.2 KB paint at 10 s held the pty vote for the full window and the opening run landed at exactly the
# 40 s allowance (5 s keeps tmux's 100 B / 15 s clock under the 30 B/s threshold and clears the paint in 5 s);
# and a compressed run scales the policy's grace by COMPRESSION like its window, since grace is a policy time
# constant and an uncompressed 10 s grace was 10% of a 90 s post phase. Labels are untouched. The hold-out
# was recorded after all of this.
AMENDMENTS = ("grace 10 s added to GRACE_GRID", "net rate over NET_WINDOW_S = 3 s instead of per tick",
              "PTY_WINDOW_S 10 -> 5 s", "compressed runs scale grace by COMPRESSION",
              "gates: every idle interval's opening BUSY run (within one interval of the open) gets the window as "
              "its tail; a run spanning the whole interval fails")
