package config

import (
	"sync"
	"testing"
	"time"

	"github.com/gofrs/flock"
)

// TestWithLockSerializesAgainstALiveSlowHolder proves the bug this fix closes:
// a holder that is merely slow (not crashed) must never have its lock stolen,
// and the two writers' fn calls must never run concurrently. The old
// mtime-staleness scheme would misdiagnose a holder still working past 10s as
// abandoned; a real OS advisory lock never does, however long the holder runs.
func TestWithLockSerializesAgainstALiveSlowHolder(t *testing.T) {
	c := newTestConfig(t)

	var mu sync.Mutex
	inFlight := false
	overlapped := false
	var order []string

	holdFor := 150 * time.Millisecond

	run := func(name string, hold time.Duration) {
		err := c.withLock(func() error {
			mu.Lock()
			if inFlight {
				overlapped = true
			}
			inFlight = true
			order = append(order, name+":start")
			mu.Unlock()

			time.Sleep(hold)

			mu.Lock()
			order = append(order, name+":end")
			inFlight = false
			mu.Unlock()
			return nil
		})
		if err != nil {
			t.Errorf("%s: withLock returned error: %v", name, err)
		}
	}

	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		run("A", holdFor)
	}()
	// Give A a head start so it reliably acquires the lock first.
	time.Sleep(20 * time.Millisecond)
	go func() {
		defer wg.Done()
		run("B", 10*time.Millisecond)
	}()
	wg.Wait()

	if overlapped {
		t.Fatalf("A and B's fn calls overlapped — lock did not serialize a live holder: %v", order)
	}
	if len(order) != 4 {
		t.Fatalf("expected 4 ordered events, got %v", order)
	}
	// A must fully finish (start+end) before B starts, since A held the lock
	// first and B must wait for the real holder rather than stealing it.
	if !(order[0] == "A:start" && order[1] == "A:end" && order[2] == "B:start" && order[3] == "B:end") {
		t.Fatalf("expected A to fully finish before B started, got %v", order)
	}
}

// TestWithLockConcurrentWritersNeverCorruptTheFile drives many concurrent
// AddWorkroom calls (real withLock-guarded mutators) and asserts every one of
// them lands in the final config — proving the lock actually prevents the
// lost-update race the old stale-timeout scheme allowed.
func TestWithLockConcurrentWritersNeverCorruptTheFile(t *testing.T) {
	c := newTestConfig(t)

	const n = 20
	var wg sync.WaitGroup
	errs := make([]error, n)
	for i := range n {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			errs[i] = c.AddWorkroom("/proj", nameFor(i), pathFor(i), "git")
		}(i)
	}
	wg.Wait()

	for i, err := range errs {
		if err != nil {
			t.Fatalf("AddWorkroom %d failed: %v", i, err)
		}
	}

	names, err := c.WorkroomNames("/proj")
	if err != nil {
		t.Fatal(err)
	}
	if len(names) != n {
		t.Fatalf("expected %d workrooms, got %d: %v (lost-update corruption)", n, len(names), names)
	}
}

func nameFor(i int) string { return "wr" + string(rune('a'+i%26)) + string(rune('0'+i/26)) }
func pathFor(i int) string { return "/wr/" + nameFor(i) }

// TestWithLockReleasedImmediatelyWhenHolderDies proves the property that makes
// the stale-timeout heuristic unnecessary: an OS advisory lock is released by
// the kernel the instant the holding file descriptor closes (simulating a
// crashed process), not after some elapsed-time guess. A fresh acquisition on
// the same path must succeed right away — no waiting for any staleness window.
func TestWithLockReleasedImmediatelyWhenHolderDies(t *testing.T) {
	c := newTestConfig(t)
	lockPath := c.Path() + ".lock"

	// Simulate another process holding the lock, then dying without a clean
	// unlock — closing the fd is what a crash does; gofrs/flock's Close() is
	// the OS-level equivalent (no explicit Unlock call).
	crashed := flock.New(lockPath)
	locked, err := crashed.TryLock()
	if err != nil || !locked {
		t.Fatalf("setup: could not take the simulated crashed holder's lock: locked=%v err=%v", locked, err)
	}
	if err := crashed.Close(); err != nil {
		t.Fatalf("setup: closing the simulated crashed holder's fd: %v", err)
	}

	// A fresh call must succeed immediately — no 10s (or any) staleness wait.
	start := time.Now()
	if err := c.withLock(func() error { return nil }); err != nil {
		t.Fatalf("withLock after a crashed holder returned error: %v", err)
	}
	if elapsed := time.Since(start); elapsed > time.Second {
		t.Fatalf("withLock took %v after a crashed holder — expected near-instant reacquisition", elapsed)
	}
}
