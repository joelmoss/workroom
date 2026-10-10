# The wr-agent terminal frame is deliberately duplicated in Swift and Rust

The terminal service's frame (1-byte kind, 4-byte big-endian length, payload, capped at 1 MiB) exists in both Swift and Rust. A Swift client has to speak the wire, so Swift keeps its codec and the Rust copy reproduces three Swift decoder behaviours exactly: sticky failure, length checked before kind, and partial frames kept. The tests on both sides are what keep the two honest.

Source: [`vcs/crates/wr-agent/src/protocol/frame.rs`](../../vcs/crates/wr-agent/src/protocol/frame.rs) (module comment), [`macapp/Packages/WorkroomWire`](../../macapp/Packages/WorkroomWire/Sources/WorkroomWire/SessionFrame.swift).
