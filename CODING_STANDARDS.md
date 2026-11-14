# Coding standards

Rules a reviewer applies to a diff. Mechanical rules live in the linters and CI scripts instead
(`make pre-push` runs them); these are the judgement calls no check can make.

## Tests

- **Time budgets survive a busy CI runner.** A test whose pass depends on wall-clock time (a
  timeout, a grace period, a deadline it races) either takes an injected clock, or gives the
  thing it waits on at least 3 s and names what it waited for in the assertion. CI's macOS
  runners run every package's tests at once: budgets of 0.5 s and 1 s for a git commit or a
  first read, which pass locally every time, failed there.
