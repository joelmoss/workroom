# Jev opportunities for Workroom

Research and product exploration consolidated September 18, 2026.

Workroom could use Jev to help users supervise parallel work, understand changes, find relevant context, and move pull requests through CI and review. The strongest opportunities combine Workroom's existing terminal, VCS, and session data with narrow semantic judgments.

This document consolidates the discussion, merges overlapping suggestions, and ranks proposals by expected usefulness, evidence of model fit, implementation dependencies, and ease of validation. Rankings are recommendations, not an approved roadmap. No Jev integration or live Workroom benchmark has been implemented.

## Browse by priority

| Priority | Meaning | Leading ideas |
| --- | --- | --- |
| **P1 — Start here** | High-value, bounded features or necessary foundations | Changes since last review; CI failure cards; semantic search; attention queue; PR watching; internal issue triage |
| **P2 — Build next** | Useful extensions once evidence collection, indexing, and event monitoring exist | Review feedback queue; review packets; related files; agent context packets; purpose groups; CI history |
| **P3 — Explore** | Promising but more speculative, operationally complex, or dependent on reliable earlier features | Bounded CI repair; cross-workroom coordination; configurable semantic automation; regression investigation |

Items are ordered within each group. Priority applies across groups; numbering is a stable reference, not a global score. Some highly useful features need no AI.

Each group's table is a quick index; the entries below it add practical detail and an illustrative example. All examples describe proposed behavior, not existing functionality or measured model results.

## 1. Changes and review

| ID | Priority | Idea | Succinct summary | Jev's role |
| --- | --- | --- | --- | --- |
| CH-1 | **P1** | **Changes since last review** | Capture what the user reviewed and highlight new files or modified hunks when an agent continues working. Preserve reviewed status only for unchanged content. | Optional classification of new edits; snapshot comparison belongs in code. |
| CH-2 | **P1** | **Review navigation essentials** | Add path filtering, reviewed markers, next-unreviewed navigation, and an explicit comparison baseline. | None required. |
| CH-3 | **P2** | **Guided review order** | Suggest an order that introduces interfaces and models before implementations, callers, tests, and documentation. Open exact files and hunks. | Rank candidate review steps using structural context. |
| CH-4 | **P2** | **Group changes by purpose** | Organize a large diff into related work, such as session recovery, supporting tests, logging, and formatting. Review or select a group together. | Assess relationships and classify roles; free-form group names need templates, existing task labels, or a generator. |
| CH-5 | **P2** | **Scope-drift prompts** | Compare changes with the task or an explicit expected-changes list and surface edits that may be unrelated. | Score task relevance and identify uncertain outliers. |
| CH-6 | **P2** | **Missing companion work** | Surface related tests, callers, configuration, serialization definitions, or documentation that may need inspection after a change. | Rank candidates retrieved through symbols, dependencies, and conventions. |
| CH-7 | **P2** | **Compare versions of a change** | Compare work before and after an agent repair, review response, amendment, rebase, or JJ rewrite. | Classify differences as requested fixes, supporting edits, or additional behavior. |
| CH-8 | **P2** | **Precise commit composition** | Improve staged-versus-working-copy visibility for Git and explore hunk selection alongside existing file selection. Purpose groups could help prepare a selection. | Optional grouping assistance; selection and VCS operations remain deterministic. |

**Feedback:** CH-1 is the strongest starting point in this area. Review baselines must be content snapshots, independent of mutable branch labels or commit descriptions. Proposed groups may overlap and do not prove that each group is an independently valid commit. Scope and missing-test findings should invite inspection rather than declare a defect. Preserve the different Git and JJ models instead of imposing Git staging semantics on JJ.

### CH-1 · Changes since last review

Store a review checkpoint and compare subsequent file content against it. Mark newly edited hunks as needing review while keeping unchanged content reviewed, even if an agent amends a commit.

**Example:** You review six files, then ask an agent to fix one edge case. On returning, Workroom shows “2 files changed again · 1 new test file” and opens only the new differences.

### CH-2 · Review navigation essentials

Provide a path filter, explicit reviewed toggles, a next-unreviewed shortcut, and a visible baseline selector. Keep selections stable while files change, and make it clear whether the view compares against the working-copy parent, a branch base, or a review checkpoint.

**Example:** Filter a large diff to `macapp/`, review each file with the keyboard, and return later to the four remaining unreviewed files.

### CH-3 · Guided review order

Build a suggested reading sequence from changed definitions, their implementations, callers, and tests. The user can follow that sequence or return to ordinary file ordering; each step points to concrete code.

**Example:** For a session-protocol change, start with the new message fields, then inspect the sender, receiver, and compatibility tests.

### CH-4 · Group changes by purpose

Offer an alternative view that groups related files or hunks under a task or purpose. Allow mixed-purpose files to appear in multiple groups, with their relevant hunks selected, and expose the original complete diff throughout.

**Example:** A 25-file change becomes “Session recovery,” “Supporting tests,” and “Logging cleanup.” The user reviews recovery first and considers leaving the logging cleanup for a separate commit.

### CH-5 · Scope-drift prompts

Use an attached task description or user-defined expected-changes list to assess each part of a diff. Show a small number of potentially unrelated changes with the source task alongside them, so the user can confirm a legitimate dependency or ask for an explanation.

**Example:** A terminal-restoration task also changes update-channel selection. Workroom surfaces that file with “Check whether this belongs to the current task.”

### CH-6 · Missing companion work

Retrieve callers, related tests, serialization definitions, and documentation around modified interfaces. Rank which unchanged companions are worth checking; present these as inspection suggestions rather than automatic findings.

**Example:** An agent adds a session message field. Workroom links the older-version decoder and compatibility fixtures that may need corresponding updates.

### CH-7 · Compare versions of a change

Let users name or select two captured versions and inspect their differences. Keep both original identities available after amendments or rewrites, and distinguish intervening base-branch changes where possible.

**Example:** Compare “Before review feedback” with the current revision to see whether an agent only added the requested timeout handling or also changed retry behavior.

### CH-8 · Precise commit composition

Give the user an accurate preview of the content a commit would record, with Git index and working-copy differences visible. Explore hunk selection separately from semantic grouping, and revalidate the selected content if an agent edits it before commit.

**Example:** A file contains a bug fix and a logging experiment. The user selects only the fix and its test, then inspects the proposed commit diff before recording it.

## 2. Files, history, and context discovery

| ID | Priority | Idea | Succinct summary | Jev's role |
| --- | --- | --- | --- | --- |
| FH-1 | **P1** | **Find files by behavior** | Search for “where sessions are restored” or “the code deciding whether a PR can merge” and open matching files or symbols at relevant lines. | Rerank a local shortlist of paths, symbols, and content snippets. |
| FH-2 | **P1** | **Search history by behavior** | Find commits related to a symptom, feature, or previous fix using commit messages, paths, and diff content. | Rank candidate commits for semantic relevance. |
| FH-3 | **P1** | **Search development activity** | Find the terminal where signing failed, an earlier dependency error, or the previous successful resolution of a problem. | Rerank indexed commands, log excerpts, task records, and changes. |
| FH-4 | **P1** | **Panel navigation essentials** | Add fast filename filtering, reveal-current-file, copy-relative-path, remembered folder expansion, and links between Files, Changes, and History. | None required. |
| FH-5 | **P1** | **History filtering and comparison** | Add author, path, date, and branch-only filters, plus selection of two revisions to compare. | None required. |
| FH-6 | **P2** | **Related files** | Show tests, callers, definitions, configuration, documentation, and frequently co-changed files beside the selected file. | Rank relationships that structural tools and history retrieve. |
| FH-7 | **P2** | **Relevant code history** | From a file, symbol, or hunk, reveal commits that introduced the behavior, fixed edge cases, or established constraints. | Select relevant historical evidence; narrative explanations need a generator. |
| FH-8 | **P2** | **Agent context packets** | Assemble selected code, failures, related tests, previous attempts, relevant history, and repository instructions before starting an investigation. | Select bounded, attributable context and applicable skills. |
| FH-9 | **P2** | **Resume with useful context** | On returning to a workroom, recover the latest useful evidence, unresolved decisions, and prior attempts for the user or an agent. | Select existing records; free-form handoff summaries need a generator. |
| FH-10 | **P3** | **Regression candidate finder** | Given a symptom and a known-good revision, shortlist relevant commits for inspection or a bisect workflow. | Prioritize investigation; reproduction and tests establish causation. |

**Feedback:** Build one retrieval foundation that can serve files, commits, and activity. Search locally first, then send a bounded shortlist for semantic ranking. Display exact source locations and indexed coverage. The current History model's 1,000-commit display limit should not become an invisible search limit. Persisted terminal sessions alone are not a searchable activity archive. Keep structural relationships separate from inferred ones, and distinguish documented historical intent from an inferred explanation.

### FH-1 · Find files by behavior

Add an explicit semantic mode to file search. Retrieve candidates locally using paths, symbols, and content, then rank short excerpts and return exact locations with enough surrounding code to judge the match.

**Example:** Searching “where do we decide if a PR can merge?” opens the merge-eligibility property rather than only files with “merge” in their names.

### FH-2 · Search history by behavior

Search commit messages, changed paths, and indexed patches together. Return the relevant commit and matching change, with visible search scope so users know whether older history has been indexed.

**Example:** “When did terminals start surviving app restarts?” finds the implementation change and a later restoration fix, even if neither commit uses that exact wording.

### FH-3 · Search development activity

Create an opt-in, searchable record of command events and bounded output excerpts, linked to workrooms and capture times. Search can lead to an active terminal or a retained record when that session no longer exists.

**Example:** “Find the signing error from yesterday” opens the failed command and its error excerpt in the release workroom.

### FH-4 · Panel navigation essentials

Make ordinary navigation fast: filter filenames, reveal the active file, copy its relative path, and preserve each workroom's expanded folders. Add contextual links between the current file, its changes, and its history.

**Example:** While viewing a diff, choose “Reveal in Files,” then “Show file history,” and return to the original diff without losing its selected hunk.

### FH-5 · History filtering and comparison

Allow filters to compose across author, date, path, and branch scope. Let users select two revisions and open their aggregate difference using the existing changeset and diff presentation.

**Example:** Show only commits touching session code on the current branch, then compare the branch's starting revision with its current tip.

### FH-6 · Related files

Show a small contextual list beside a selected file, grouped by relationship. Use imports, references, naming conventions, and co-change history to retrieve candidates; label inferred relevance distinctly from known references.

**Example:** Opening `TerminalAgentManager.swift` offers its tests, prompt builder, runner, and banner view as useful next files.

### FH-7 · Relevant code history

Start from the user's selected symbol or hunk and find changes that introduced or modified it, including relevant predecessor paths when available. Attach original messages or linked discussions when explaining historical intent.

**Example:** Selecting a cancellation guard reveals the commit that added it and the accompanying explanation of stale asynchronous results.

### FH-8 · Agent context packets

Prepare an inspectable selection of source excerpts, tests, logs, historical changes, and project instructions. Preserve source identities and let the user remove irrelevant material before launching the chosen agent.

**Example:** From a failed session test, “Investigate with context” includes the assertion, affected implementation, compatibility tests, and the recent protocol change.

### FH-9 · Resume with useful context

Capture task milestones and select the evidence most useful when work resumes. Present pending decisions, the last validation result, and prior attempts as linked records; generate prose only when needed.

**Example:** On Monday, a workroom shows that the parser fix is implemented, a compatibility test still fails, and the previous agent was waiting for a decision about older clients.

### FH-10 · Regression candidate finder

Limit candidate commits to a user-supplied working/failing range, then rank changes related to the symptom and affected code. Offer direct inspection or a prepared investigation handoff; keep any bisect execution a separate operation.

**Example:** Terminal restoration worked in one release but fails in the next. Workroom highlights three attachment-related commits to investigate first.

## 3. Pull requests and CI

| ID | Priority | Idea | Succinct summary | Jev's role |
| --- | --- | --- | --- | --- |
| PC-1 | **P1** | **CI failure cards** | Show the failed step, relevant log evidence, likely failure category, and actions to inspect, rerun, or investigate from the workroom. | Classify failures and select evidence; agents explain complex causes and implement fixes. |
| PC-2 | **P1** | **Watch a PR** | Monitor a selected PR beyond sidebar selection and notify when CI completes, reviews arrive, repairs finish, or a human decision is needed. | Judge whether new information is materially different and what attention it needs. |
| PC-3 | **P2** | **Review feedback queue** | Turn review threads into actionable items, distinguish code requests from questions or design decisions, and group duplicate human or bot feedback. | Classify, group, and route individual threads. |
| PC-4 | **P2** | **Review packet for the latest revision** | Present changes since the last review, validation evidence, remaining threads, acceptance-criterion gaps, and claims needing verification. | Match claims to evidence and prioritize inspection. |
| PC-5 | **P2** | **Merge eligibility and unresolved concerns** | Explain authoritative GitHub blockers alongside clearly separate advisory findings, such as scope concerns or missing validation evidence. | Identify advisory concerns; GitHub and application rules determine eligibility. |
| PC-6 | **P2** | **Recurring CI failure memory** | Match failures to earlier incidents, attempted remedies, base-branch failures, and retry outcomes. | Recognize semantically similar failures; code calculates recurrence and outcomes. |
| PC-7 | **P3** | **Bounded “Get CI passing” workflow** | Gather evidence, launch a repair agent, validate, optionally push under an explicit policy, watch the new run, and stop at defined limits. | Route investigation and distinguish repeated, new, or unresolved failures. |
| PC-8 | **P3** | **Coordinate related PRs** | Surface dependencies, overlapping interfaces, useful review order, and workrooms that may need refreshing after another PR merges. | Assess relationships among structurally selected PR pairs. |
| PC-9 | **P3** | **Shared CI incident detection** | Recognize when several PRs fail for the same external reason and present one incident with linked evidence. | Group related symptoms; code establishes timing and affected runs. |

**Feedback:** PC-1 is the best first Jev experiment here. Distinguish tests failing from tests never running. A model's “appears addressed” assessment must remain separate from a GitHub thread's resolved state. Do not reduce merge readiness to one AI percentage. Reserve “flaky” for historical evidence, and never let grouping hide a newly different failure. GitHub Actions logs and reruns are accessible through its API; other CI providers need adapters. Desktop monitoring while the app is closed requires a background or hosted service.

### PC-1 · CI failure cards

Fetch failed job steps, annotations, and bounded log excerpts for a specific run attempt. Show whether tests ran, a likely failure category, the selected evidence, and actions appropriate to the available provider integration.

**Example:** “Dependency download failed before tests started” links the registry error and offers “View log,” “Rerun failed jobs,” and “Investigate.”

### PC-2 · Watch a PR

Persist an explicit watch and observe changes in check results, reviews, and PR revisions. Deduplicate repeated events, retain links to the affected revision, and notify when there is a new actionable state.

**Example:** You switch to another workroom after pushing. Workroom later reports that CI passed but a reviewer has asked a design question, with a link to that thread.

### PC-3 · Review feedback queue

Read review-thread contents and separate implementation requests, questions, design decisions, and informational comments. Group apparent duplicates and let the user hand a selected set of implementation items to an agent.

**Example:** A human and a bot both request timeout coverage. They appear as one work item with two source threads, while a question about API behavior remains assigned to the user.

### PC-4 · Review packet for the latest revision

Combine the PR's latest diff, changes since a review checkpoint, checks for the tested revision, and unresolved feedback. Flag gaps between the task or PR claims and recorded evidence, rather than certifying completeness.

**Example:** The packet says “Retry behavior changed; tests passed for the latest revision; one compatibility question remains,” with links to each supporting source.

### PC-5 · Merge eligibility and unresolved concerns

Present authoritative blockers from GitHub separately from model-assisted review suggestions. Refresh relevant state before a merge action, and show specific outstanding items rather than a single synthesized readiness score.

**Example:** GitHub reports missing approval. Alongside that fact, Workroom suggests inspecting an unrelated configuration edit before requesting the final review.

### PC-6 · Recurring CI failure memory

Retain normalized failure signatures, selected evidence, attempted remedies, and outcomes under a defined retention policy. Retrieve similar cases without treating the same error text as proof of the same root cause.

**Example:** A dependency timeout card shows that two comparable earlier failures cleared on rerun, while the most recent three attempts failed identically.

### PC-7 · Bounded “Get CI passing” workflow

Offer an explicit policy defining allowed changes, validation, push behavior, and attempt limits. Prepare an agent handoff, monitor the resulting run, and stop when the revision changes unexpectedly, the same failure repeats, or a human decision is required.

**Example:** The user permits two repair attempts and pushes to the existing branch. After one fix passes locally but CI exposes a different compatibility failure, Workroom records the new evidence for the second attempt.

### PC-8 · Coordinate related PRs

Combine branch relationships, changed files, task descriptions, and relevant code to identify possible dependencies or overlapping interfaces. Suggest review order and identify workrooms worth refreshing after a merge.

**Example:** One PR changes the session message format and another adds a consumer. Workroom suggests reviewing the format change first and checking the consumer against it.

### PC-9 · Shared CI incident detection

Compare failures across watched PRs using time windows, job steps, and semantic similarity. Create one linked incident when evidence supports a common cause, while preserving individual run status and any distinct failures.

**Example:** Four unrelated PRs fail fetching the same package. Workroom groups the registry errors and leaves a separate test assertion failure visible on one PR.

## 4. Supervising parallel work

| ID | Priority | Idea | Succinct summary | Jev's role |
| --- | --- | --- | --- | --- |
| SW-1 | **P1** | **Workroom attention queue** | Prioritize workrooms waiting for a decision, blocked by environment setup, repeating failures, or ready for review. Link each item to evidence. | Classify activity; deterministic rules handle timing, repetition, and notification policy. |
| SW-2 | **P2** | **Agent completion review inbox** | Separate “agent stopped” from “task appears complete” using the task, diff, recorded validation, and unresolved questions. | Assess narrow completion claims and select evidence. |
| SW-3 | **P2** | **Contextual navigation and action suggestions** | Interpret requests such as “open the workroom waiting on review” or suggest a known runbook after a failure. | Select known workroom or action IDs, with an explicit no-match outcome. |
| SW-4 | **P2** | **Failure routing before diagnosis** | Classify a terminal failure and select an applicable runbook before invoking the existing generative diagnosis or investigation flow. | Bounded classification and selection, not explanation or command generation. |
| SW-5 | **P3** | **Cross-workroom overlap detection** | Flag potentially duplicated effort or incompatible assumptions across workrooms, including changes that have not been pushed. | Assess pairs selected by shared files, symbols, dependencies, and task references. |
| SW-6 | **P3** | **Configurable semantic automation** | Offer rules such as “notify me when a product decision is needed” or “prepare a review packet when work appears ready.” | Evaluate narrow conditions; a fixed action catalog and application policy control effects. |

**Feedback:** SW-1 is the strongest overall new product direction. Start with an advisory queue without suppressing existing notifications. Keep ordering stable as asynchronous results arrive. Terminal output is incomplete evidence of agent activity; reliable completion and permission judgments would benefit from explicit agent hooks. Begin overlap detection with same-repository, overlapping-file cases. Arbitrary workflow authoring from prose is a separate capability from evaluating predefined rules.

### SW-1 · Workroom attention queue

Create a stable queue of workrooms that appear blocked, waiting for input, repeating failures, or ready for review. Attach evidence and offer direct navigation; initially leave existing notifications intact while measuring usefulness.

**Example:** Among eight active workrooms, one requests authentication, one needs a product decision, and one has completed validation. Those three appear with distinct next actions.

### SW-2 · Agent completion review inbox

Assess completion against an explicit task and recorded activity, including changed files and validation events. Keep “agent stopped,” “appears ready,” and “reviewed by a person” as separate states.

**Example:** An agent says “done,” but the requested integration test has no recorded result. The work appears in the inbox with that evidence gap highlighted.

### SW-3 · Contextual navigation and action suggestions

Translate a short request into a selection from available workrooms or known actions. Show a preview or several candidates when the request is ambiguous, and allow a no-match result.

**Example:** “Take me to the workroom waiting on review” opens the matching workroom; if two match, the palette lists both with their review state.

### SW-4 · Failure routing before diagnosis

Classify a captured terminal failure before deciding whether a known runbook is sufficient or an agent investigation is warranted. Reuse the existing failure capture and redaction flow, and keep generated explanations in the current agent path.

**Example:** An authentication failure offers the configured login guidance. An unfamiliar build error instead prepares an “Investigate” handoff with the command and output.

### SW-5 · Cross-workroom overlap detection

Compare plausible pairs of tasks and local changes selected through shared files, symbols, or dependencies. Surface possible duplicated effort or conflicting assumptions before either workroom has a PR.

**Example:** Two agents independently change session expiry behavior in different files. Workroom links both diffs and prompts the user to check whether they agree.

### SW-6 · Configurable semantic automation

Provide a rule builder with known event sources, semantic conditions, and a fixed set of actions. Preview matches on past events so users can see when a rule would fire before enabling it.

**Example:** “When an agent asks for a product decision, notify me; otherwise collect its completed work in the review inbox.” Code applies quiet hours and notification preferences.

## 5. Internal operations, backend, and admin

These ideas can run in local tooling or delivery infrastructure; they do not require Workroom to become a hosted service.

| ID | Priority | Idea | Succinct summary | Jev's role |
| --- | --- | --- | --- | --- |
| OP-1 | **P1** | **Issue triage assistant** | Assess reproduction completeness, suggest likely components, retrieve duplicate candidates, and recommend the repository's existing triage labels. | Classify issues and rank matches for maintainer review. |
| OP-2 | **P1** | **Evaluation case collection** | Select uncertain, novel, disputed, or confidently wrong cases for human labeling and future regression evaluation. | Help prioritize examples; human judgments provide evaluation evidence. |
| OP-3 | **P2** | **Internal CI failure grouping** | Group recurring CLI, app, Rust, packaging, and release failures and retrieve previous investigations. | Reuse failure classification and matching from PC-1 and PC-6. |
| OP-4 | **P2** | **Release regression triage** | Associate new crash reports and issues with changed components, release versions, and stable/pre/nightly channels. | Match symptoms and rank candidate relationships. |
| OP-5 | **P2** | **Support runbook routing** | Select relevant troubleshooting guidance from an approved catalog and escalate unfamiliar cases. | Rank known articles or runbooks; prose responses need templates or a generator. |
| OP-6 | **P2** | **Product feedback analysis** | Classify feedback by workflow, severity, missing capability, and user segment; group repeated requests into themes. | Classification and semantic deduplication. |

**Feedback:** OP-1 is the best low-risk internal pilot using historical public issues. Recommend labels without automatically closing issues, applying `wontfix`, or posting replies. For release analysis, compute normalized rates and affected-version counts in code; report volume alone does not establish a regression.

### OP-1 · Issue triage assistant

Evaluate historical or incoming issues for reproduction detail, likely component, and similarity to existing reports. Present proposed labels and supporting excerpts for a maintainer to accept or correct.

**Example:** “Terminal disappears” lacks the app version and background-session setting. The assistant recommends `needs-info`, highlights those missing fields, and links a potentially related report.

### OP-2 · Evaluation case collection

Use model uncertainty, user corrections, unexpected outcomes, and sampled high-confidence answers to select cases for labeling. Preserve model and question versions so regressions can be traced without relying only on aggregate accuracy.

**Example:** A user dismisses a confidently classified “waiting for input” event because the process was still compiling. That event becomes a candidate regression case after review and redaction.

### OP-3 · Internal CI failure grouping

Apply the same failure-evidence pipeline to Workroom's own workflows. Route related failures by component and attach earlier investigations so maintainers can avoid rediscovering packaging or environment problems.

**Example:** Multiple release jobs fail while signing the bundled helper. They are grouped under the same suspected packaging issue with links to each failing step.

### OP-4 · Release regression triage

Join crash and issue classifications with exact version, build, channel, and component metadata. Rank possible relationships to recent changes while ordinary analytics calculate exposure and failure rates.

**Example:** Session-attachment reports increase on Nightly after a relevant change. The triage view links the reports and candidate commit, while showing whether comparable stable users are affected.

### OP-5 · Support runbook routing

Match incoming questions or diagnostic bundles to versioned, approved troubleshooting material. Surface the relevant section and escalate when the available evidence or catalog does not cover the problem.

**Example:** A user sees an empty PR panel. Their diagnostic information indicates an outdated GitHub CLI, so the suggested runbook points to upgrading it rather than signing in again.

### OP-6 · Product feedback analysis

Classify feedback into concrete workflows and requested outcomes, then group semantically similar requests while retaining every original source. Distinguish duplicate reports from independently expressed demand.

**Example:** “Remember what I reviewed,” “show only the agent's latest edits,” and “which files changed again?” are grouped under review checkpoints, with links to the original requests.

## 6. Shared foundations and constraints

| Foundation | Recommendation |
| --- | --- |
| **Immutable evidence snapshots** | Bind assessments to repository host, workroom, revision/content hash, source IDs, and capture time. Invalidate them when relevant state changes. |
| **PR and CI evidence model** | Add PR head/base SHAs, check and run IDs, attempts, tested revisions, failed steps, annotations, logs, and review threads. Preserve the distinction between branch-head and synthesized merge revisions. |
| **Local retrieval index** | Index paths, symbols, selected content, history, and opt-in activity. Retrieve locally before ranking; make coverage and retention explicit. |
| **Decision service** | Use a small provider-independent interface for typed judgments. Swift HTTP is sufficient for the app; Python is convenient for internal experiments. |
| **Versioned assessments** | Record model version, question version, evidence identity, probabilities, and resulting policy decision. Pin model versions when evaluating thresholds. |
| **Unknown and no-match outcomes** | Treat missing evidence as unknown, not as evidence that a condition is false. Preserve uncertainty rather than forcing a choice. |
| **Action boundary** | Model selection does not authorize execution. Keep writes, pushes, reruns, merges, and agent permissions under explicit application policy. |
| **Agent handoffs** | Send attributable context packets to existing coding agents for investigation, explanations, code, and arbitrary command generation. |
| **Responsiveness** | Batch related questions, debounce events, cache stable evidence, cancel stale requests, and avoid inference on every filesystem event. Keep row ordering and selection stable. |
| **Offline and failure behavior** | Core terminals, browsing, VCS, and workspace operations remain usable without inference. Add timeouts and deterministic fallbacks. |
| **Privacy** | Keep cloud inference optional, disclose uploaded context, redact locally, and verify applicable retention terms before automatic developer-context uploads. |
| **Remote support** | Make host identity part of every evidence key. Current Files and GitHub paths have local-access restrictions; remote parity requires explicit data-access work. |
| **CLI compatibility** | Keep app-only intelligence out of the stable CLI JSON contract unless there is a concrete CLI requirement. |

## 7. Jev fit: research distilled

- **Good candidate tasks:** classification, relevance ranking, bounded option selection, rubric scoring, and choosing evidence from supplied candidates.
- **Output interface:** Choice selects one option with probabilities and confidence; Noul returns a yes/no probability; Score returns a rubric-based score and distribution. Questions in one call are evaluated independently against shared state. [Primitives](https://docs.typesafe.ai/primitives)
- **Generation requires another component:** Jev does not write arbitrary explanations, patches, commit messages, or commands. Extraction works by selecting candidate values or spans. [Known limitations](https://docs.typesafe.ai/model-jaggedness/jev-1.13)
- **Correct shape is not correct meaning:** bounded outputs prevent invented options, but the model can choose wrongly. Its confidence statistic is derived from its distribution and needs workload-specific validation. [Confidence](https://docs.typesafe.ai/confidence)
- **Documented weaknesses:** arithmetic, counting, date comparisons, complex indirection, distracting context, and adversarial input. Keep exact computations and structural invariants in code. [Known limitations](https://docs.typesafe.ai/model-jaggedness/jev-1.13)
- **September 18 model snapshot:** `jev-1.13.0`; text-only input; 64K total request budget and 32K for state plus the longest question. Published limits are 1,200 requests/minute and 250,000 tokens/second, subject to change. No customer fine-tuning. [Models](https://docs.typesafe.ai/models)
- **Published economics:** $0.042 per million input tokens, free output. At 5,000 total input tokens per event, 100 events/day for 30 days costs approximately $0.63 per user in model charges. Continuous 1 Hz evaluation for eight hours/day over 22 days would cost approximately $133. Event-driven usage matters. [Pricing](https://typesafe.ai/)
- **Latency:** the vendor advertises 70–500 ms, primarily measured from the US West Coast. Treat this as a published observation, not a regional or production guarantee. [Launch](https://typesafe.ai/blog/introducing-system-one-models-and-jev)
- **Evidence quality:** independent retrieval and context-selection experiments are encouraging, while classification quality and calibration vary materially by task. Vendor workflow evaluations use frontier-model consensus rather than independently verified ground truth. [Reranking study](https://github.com/anessbelbati/jev-rerank-bench), [Aera context-selection study](https://aerabrowser.com/news/agent-memory-doesnt-need-a-generator-typesafes-jev-vs-llm-on-400-real-tasks), [Classification pilot](https://github.com/AbdelStark/jev-benchmarks), [Vendor methodology](https://evals.typesafe.ai/)
- **Data handling:** TypeSafe documents no training on customer requests and enterprise zero-data-retention arrangements. Verify the applicable agreement and retention behavior before adopting automatic uploads. A local Jev deployment or production SLA was not established in this research. [Legal documentation](https://docs.typesafe.ai/legal)

## 8. Recommended sequence and validation

1. **Establish review and navigation foundations.** Build CH-1 and the non-AI essentials in CH-2, FH-4, and FH-5. These remain valuable regardless of model choice.
2. **Run two bounded Jev pilots.** Use OP-1 for historical public issue triage and PC-1 for CI failure classification with inspectable evidence.
3. **Build shared retrieval.** Deliver FH-1 and FH-2, then related files and context packets. Add activity search once collection and retention are defined.
4. **Connect events to attention.** Introduce PC-2 and SW-1 in shadow mode, then expose advisory queues and notifications.
5. **Complete the review loop.** Add review feedback, latest-revision packets, completion review, and recurring failure memory.
6. **Evaluate greater automation.** Explore bounded repair, semantic rules, and cross-workroom coordination only after the underlying evidence and monitoring prove reliable.

For each pilot, compare against simple deterministic rules and the existing agent-based approach. Separate development cases from an untouched evaluation set. Measure precision, missed important events, useful coverage at an acceptable error rate, p95 latency, and cost per useful result. Include stale state, incomplete evidence, unfamiliar tools, misleading logs, and adversarial comments.

Product-specific success measures should include time to locate the right file or commit, repeated review effort, time from CI failure to useful investigation, actionable-notification rate, and maintainer time saved. Thresholds and automation limits should follow those results rather than a universal confidence cutoff.

## 9. Repository anchors

- [Changes and inspector panels](../../macapp/WorkroomApp/Views/ChangesPanel.swift)
- [Commit selection and Git/JJ behavior](../../macapp/WorkroomApp/Core/CommitDraft.swift)
- [Shared changeset viewer](../../macapp/WorkroomApp/Views/ChangesetDetailView.swift)
- [Files panel](../../macapp/WorkroomApp/Views/FilesPanel.swift) and [file-tree model](../../macapp/WorkroomApp/Core/FileTreeModel.swift)
- [History panel](../../macapp/WorkroomApp/Views/HistoryPanel.swift) and [history model](../../macapp/WorkroomApp/Core/HistoryModel.swift)
- [PR panel](../../macapp/WorkroomApp/Views/PullRequestPanel.swift) and [GitHub repository adapter](../../macapp/WorkroomApp/Core/RepositoryGitHub.swift)
- [PR/CI resolution](../../macapp/WorkroomApp/Core/WorkroomStatusResolver.swift) and [refresh/action lifecycle](../../macapp/WorkroomApp/Core/AppStore+WorkroomStatus.swift)
- [Terminal diagnosis](../../macapp/WorkroomApp/Core/TerminalAgentManager.swift) and [generative diagnosis contract](../../macapp/WorkroomApp/Core/AgentPrompt.swift)
- [Notifications](../../macapp/WorkroomApp/Core/NotificationCenterStore.swift)

These references describe the inspected working tree, which includes ongoing changes; they are not a claim about a particular released version.
