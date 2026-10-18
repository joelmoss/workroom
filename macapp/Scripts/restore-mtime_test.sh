#!/bin/sh
# Test for restore-mtime.py against a throwaway repository: a file's mtime becomes the time of
# the last commit that touched it, not the checkout's, and a file untouched since an earlier
# commit keeps that earlier commit's time.
set -eu

DIR="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/restore-mtime_test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

cd "$TMP"
git init -q
git config user.email tests@workroom.invalid
git config user.name "Workroom Tests"
mkdir -p dir/sub
echo one > old.txt
echo one > dir/sub/new.txt
echo keep > dir/sub/kept.txt
git add old.txt dir/sub/new.txt dir/sub/kept.txt
GIT_AUTHOR_DATE=1700000000 GIT_COMMITTER_DATE=1700000000 git commit -q -m first
echo two > dir/sub/new.txt
GIT_AUTHOR_DATE=1700003600 GIT_COMMITTER_DATE=1700003600 git commit -q -am second

# A checkout's stamps: everything is "now", directories included, and an untracked entry (a build
# dir, say) must not carry its own "now" up into them.
touch old.txt dir/sub/new.txt dir dir/sub
mkdir dir/untracked

python3 "$DIR/restore-mtime.py" > out.txt
cat out.txt

fail=0
mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1"; }
[ "$(mtime old.txt)" -eq 1700000000 ] || { echo "FAIL: old.txt mtime $(mtime old.txt), want the first commit's 1700000000"; fail=1; }
[ "$(mtime dir/sub/new.txt)" -eq 1700003600 ] || { echo "FAIL: new.txt mtime $(mtime dir/sub/new.txt), want the second commit's 1700003600"; fail=1; }
for d in dir dir/sub; do
  [ "$(mtime $d)" -eq 1700003600 ] || { echo "FAIL: $d mtime $(mtime $d), want its newest tracked entry's 1700003600"; fail=1; }
done
[ "$(mtime dir/sub/kept.txt)" -eq 1700000000 ] || { echo "FAIL: kept.txt mtime $(mtime dir/sub/kept.txt), want the first commit's 1700000000"; fail=1; }
grep -q '3 files stamped, 0 not in the fetched history' out.txt || { echo "FAIL: unexpected report: $(cat out.txt)"; fail=1; }

# A merge lists what it brought in: a branch commit dated 1700000900 (before "second") lands by a
# merge at 1700007200, and its file takes the merge's time, the landing time, not the author's.
git checkout -q -b side HEAD~1
echo side > side.txt
git add side.txt
GIT_AUTHOR_DATE=1700000900 GIT_COMMITTER_DATE=1700000900 git commit -q -m side
git checkout -q -
GIT_AUTHOR_DATE=1700007200 GIT_COMMITTER_DATE=1700007200 git merge -q --no-ff -m merged side
touch side.txt
python3 "$DIR/restore-mtime.py" > /dev/null
[ "$(mtime side.txt)" -eq 1700007200 ] || { echo "FAIL: side.txt mtime $(mtime side.txt), want the merge's landing time 1700007200"; fail=1; }

# --fresh: what differs from the index the cache was built from is made newer than any cached
# artifact, whatever its landing time (cargo reuses an artifact whose mtime beats the source's),
# and a deletion refreshes its directory. A fourth commit, dated BEFORE the merge, changes old.txt
# and deletes new.txt; dir and dir/sub are back-dated first so only the script can freshen them.
git ls-files -s -z > .git/built-from-index
echo four > old.txt
git rm -q dir/sub/new.txt
GIT_AUTHOR_DATE=1700001800 GIT_COMMITTER_DATE=1700001800 git commit -q -am fourth
before=$(date +%s)
touch -t 200001010000 old.txt dir dir/sub
python3 "$DIR/restore-mtime.py" --fresh .git/built-from-index > out2.txt
cat out2.txt
[ "$(mtime old.txt)" -ge "$before" ] || { echo "FAIL: old.txt mtime $(mtime old.txt) is not fresh, want >= $before"; fail=1; }
[ "$(mtime dir/sub)" -ge "$before" ] || { echo "FAIL: dir/sub mtime $(mtime dir/sub) is not fresh after a deletion inside it"; fail=1; }
[ "$(mtime dir)" -ge "$before" ] || { echo "FAIL: dir mtime $(mtime dir) is not fresh"; fail=1; }
[ "$(mtime dir/sub/kept.txt)" -eq 1700000000 ] || { echo "FAIL: kept.txt mtime $(mtime dir/sub/kept.txt) changed, want 1700000000"; fail=1; }
grep -q '2 paths differing from .git/built-from-index left fresh' out2.txt || { echo "FAIL: unexpected report: $(cat out2.txt)"; fail=1; }
python3 "$DIR/restore-mtime.py" --fresh 2>/dev/null && { echo "FAIL: a bad argument list was accepted"; fail=1; }

[ "$fail" -eq 0 ] && echo "restore-mtime_test: OK"
exit "$fail"
