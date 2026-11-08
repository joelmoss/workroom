# Cross-user usage analytics

Workroom doesn't collect usage data across users. The request was to send each user's tally of unrecognised terminal tools (`UnrecognizedToolUsage`, #141) to a server, to decide which tools get a favicon in the tab strip.

## Why this is out of scope

It depends on analytics infrastructure, which doesn't exist (#92 was its proposal). Building it would mean a server, consent and opt-out handling, and privacy wording, for a single use case: favicon prioritisation. The local tally already shows what runs on one Mac, and the owner decided not to pursue the cross-user version (2026-11-08).

## If this comes back

Reopen it if Workroom gains opt-in analytics for some other reason. This would then be a cheap second use of it.

## Prior requests

- #152: "Cross-user usage tracking for unrecognized terminal tools (favicon prioritization)"
