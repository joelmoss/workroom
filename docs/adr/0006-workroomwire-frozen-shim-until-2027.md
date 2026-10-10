# WorkroomWire is frozen, and the attach-only `workroom-session` shim stays until at least 2027

The session wire package is frozen byte for byte: its one real peer is the daemon a v2.0.0 app left running, which can never be rebuilt to match a change. The Swift attach client and its pinned v2.0.0 binary fixture stay in the tree, and `SessionShimCompatibilityTests` runs that binary. Deleting early would strand exactly the users the shim was added for, and nothing signals when that population reaches zero, so retirement is a judgement call not due before 2027.

Source: [`macapp/Packages/WorkroomWire/Package.swift`](../../macapp/Packages/WorkroomWire/Package.swift) (header comment), the open `TODOS.md` entry "Retire the attach-only `workroom-session` shim".
