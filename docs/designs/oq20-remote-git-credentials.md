# OQ20: how a remote workroom pushes when the user is not a repo admin

**Answer: the products surveyed solve this with an app they own and a server they run.** Mostly that app is
a GitHub App; Ona, boxd's personal connection and Claude's `/web-setup` use OAuth App tokens, and that
difference decides the non-admin case (see "GitHub primitives"). Each product that keeps pushing with no
client connected (Claude Code cloud sessions, Amp orbs, boxd, Coder, Codespaces,
Copilot) keeps the long-lived part of the credential on its own server. The sandbox gets one of three things:

- **nothing usable.** A proxy swaps a scoped credential for the real token and enforces the branch
  (Anthropic).
- **a short-lived real token, on demand, through a git credential helper,** never written to disk (Amp,
  boxd, Coder).
- **a platform-issued short-lived token** (Codespaces, Copilot). Copilot also cannot run `git push` at all.

None of them asks for admin per sandbox, and none of them uses deploy keys as a primary path (Anthropic's
self-hosted guide lists a read-only deploy key only as an image-level fallback). Where there is a GitHub
App, admin shows up exactly once: an org owner installs it. After that every writer gets a token that acts as them,
limited to what both the user and the App are allowed to do.

**That GitHub App does not remove the admin dependency. It amortises it.** A deploy key needs repo admin
for every workroom, forever. A GitHub App needs an org owner, or a repo admin for that repo, once per org. A
writer who is neither can only *request* the install, and GitHub notifies the owner. So the honest answer to
OQ20 is weaker than "non-admins can do it": non-admins can do it once somebody with admin has said yes one
time.

Workroom has no server, so it cannot copy the field exactly. The options that fit its constraints:

| | Option | Main trade-off |
|---|---|---|
| **A** | **Keep the deploy key. Try the `POST` and fall back on 403.** | Narrowest credential there is (one repo, revoked on destroy, Mac stores nothing), and already measured. Useless for writers and in orgs with deploy keys disabled. |
| **B** | **A Workroom-registered GitHub App. The VM runs the device flow after the fork and keeps its own refresh chain.** | Works for writers and with the laptop closed, and the Mac still stores nothing. The costs: one browser approval per workroom, and the VM holds a 6-month rotating refresh token that Workroom cannot revoke on destroy. Its scope is every repo that both the user and the installation reach, not one repo. |
| **C** | **The provider supplies the credential, declared as a driver trait (boxd today).** | No Workroom secret at all, but it is not portable. boxd's personal connection is a `repo`-scoped OAuth token covering every repo the user can reach. |
| (D) | A broker that Workroom runs (what the field does) | Removes B's costs: tokens can be narrowed and revoked per workroom, and there is no per-workroom approval. The cost is that Workroom becomes a hosted service that holds users' GitHub refresh tokens. |

**A fine-grained PAT** is the option that plainly breaks premise 6. By default an org owner must approve each
token that can reach the org. It has to be created by hand in the web UI, lives up to 366 days under the
default org policy, and cannot be minted per workroom. Keep it as a last resort, if at all. **A machine
user** and **installation tokens minted from an App private key without a server** are rejected (see
"Mapping to Workroom").

**Recommendation, for the owner to decide:** A first; on a 403, B; C as an optional per-driver accelerator,
not the portable answer. The decision the owner actually has to make is between B and D: is one browser
approval per workroom, plus a VM-held refresh token that lingers after destroy, an acceptable price for not
running a server? The spike list at the end says what to measure before choosing.

**Owner's decision, 2026-09-27: D, a broker that Workroom runs.** How it is built, and how it fits several
providers, is recorded under OQ20 in `remote-workrooms.md`. Two things changed after the decision, both
recorded there: git uses installation tokens with a per-mint authorization check, not scoped user tokens,
because of the token cap below; and the Mac authenticates to the broker with a Secure Enclave key. The
exe.dev and other-provider findings, the "Added 2026-09-27" primitives and the status of each open point
were added after the decision.

Sources: every claim links to the document that owns it. Claims that rest on a secondary source or could not
be confirmed are marked **(unverified)** and collected at the end.

## Per-product findings

### Claude Code cloud sessions (claude.ai/code)

- **Mechanism.** Two ways to connect. One is the Claude GitHub App: you authorize it, and it has to be
  installed on an account for that account's private repos. The other is `/web-setup`, which "reads the
  token that `gh auth token` prints … and sends the token to Anthropic". A session then "can access any
  repository that token can access, with no Claude GitHub App installation"
  ([web quickstart](https://code.claude.com/docs/en/web-quickstart#connect-from-your-terminal),
  [auth options](https://code.claude.com/docs/en/claude-code-on-the-web#github-authentication-options)).
- **Where it lives.** "In Anthropic-hosted environments, your GitHub credentials stay encrypted on
  Anthropic's servers and never enter a session's VM. GitHub operations from the VM go through the GitHub
  proxy, which attaches the credential on the server side"
  ([cloud sessions](https://code.claude.com/docs/en/claude-code-on-the-web#github-authentication-options)).
  "The git client inside the VM uses a scoped credential, which the proxy verifies and swaps for your actual
  GitHub token". `GH_TOKEN` and `GITHUB_TOKEN` read as the placeholder `proxy-injected`
  ([GitHub proxy](https://code.claude.com/docs/en/cloud-environments#github-proxy)). The engineering post
  says the same: "Sensitive credentials (such as git credentials or signing keys) are never inside the
  sandbox" ([sandboxing post](https://www.anthropic.com/engineering/claude-code-sandboxing)).
- **Scope, enforced at the proxy.** "`git push` works only against the session's current working branch".
  API requests "reach only repositories attached to the session", and only a pinned set of GraphQL
  operations is allowed ([GitHub proxy](https://code.claude.com/docs/en/cloud-environments#github-proxy)).
  Routines push to `claude/`-prefixed branches, and pushes elsewhere are pre-checked against branch
  protection and other people's commits
  ([routines](https://code.claude.com/docs/en/routines#repositories-and-branch-permissions)).
- **Acts as.** The user, for the push and the PR: "commits and pull requests carry your GitHub user"
  ([routines](https://code.claude.com/docs/en/routines)). The commit identity is `Claude
  <noreply@anthropic.com>`, signed through Anthropic's signing service, with a `Co-authored-by:` trailer
  for the session creator. That setup is described on the self-hosted page as "matching Anthropic-hosted
  sessions" ([self-hosted git](https://code.claude.com/docs/en/self-hosted-environments-deploy#let-the-runner-configure-git)).
- **Approval and org policy.** "On a GitHub organization, an organization owner may need to approve the
  installation." On Team and Enterprise plans a Claude org Owner must also turn the GitHub connector on
  ([web quickstart](https://code.claude.com/docs/en/web-quickstart#connect-github)). `/web-setup` is the
  way around a missing App install, because it uses the user's own `gh` token.
- **Lifetime.** Not documented. Routines skip runs "for up to 72 hours" when the connection "is missing or
  expired", which suggests the server refreshes the token (an inference, not a stated fact).
- **The case closest to Workroom's: self-hosted runners.** Here Anthropic is not the credential holder, and
  its guidance is the shape this note recommends: "Don't bake long-lived or broadly-scoped push credentials
  into a shared runner image … Instead, mint a short-lived, least-scoped token per session from your wrapper
  script … Pair it with an ephemeral per-session container … so no credential outlives the session that
  minted it". The alternative is opting back into Anthropic's proxy, which "uses the GitHub or GitHub
  Enterprise OAuth token stored for the session creator; for bot and agent sessions, it uses your
  organization's GitHub App installation token … the runner image needs no git credentials at all"
  ([self-hosted git](https://code.claude.com/docs/en/self-hosted-environments-deploy#configure-git)).
- **Does the sandbox see a raw long-lived token?** No, on Anthropic-hosted environments, unless the user
  sets `GH_TOKEN` in the environment themselves.

### Amp orbs (ampcode.com)

An orb is Amp's per-thread cloud machine. It "keeps working while your laptop is closed", and "sleeping orbs
don't cost anything" ([what are orbs](https://ampcode.com/what-are-orbs)). The name means what the question
assumed.

- **Mechanism.** A GitHub App, authorized and installed. "Amp uses the authorization to act as you when it
  talks to GitHub." Writing needs the install: "Amp can only write to a repository when the Amp app is
  installed … This is true even if your GitHub account is an admin of the repository"
  ([GitHub & Git](https://ampcode.com/docs/github)). That is the user-to-server intersection rule (see
  "GitHub primitives").
- **Where it lives.** On Amp's server. "Amp does not place a long-lived token in the orb." The clone
  credential "applies only to the clone command and is discarded afterwards". After that, "Git asks a
  credential helper, and the helper asks Amp for a short-lived token for your account". "The token is never
  written to disk or included in the project snapshot that later orbs start from"
  ([GitHub & Git](https://ampcode.com/docs/github)). That last sentence is OQ10's rule, implemented.
- **Scope.** "Any repository on github.com that your connection can reach, not only the project's
  repository." `gh` gets its token the same way. SSH URLs are rewritten to HTTPS, like boxd's.
- **Acts as.** The user. "Pushes, branches, and pull requests show up on GitHub under your account", with a
  `Co-authored-by: Amp` trailer. Signing is optional, with the key held on Amp's server.
- **Approval.** "If your organization requires approval for third-party apps, an organization owner has to
  approve the installation." A missing install surfaces as `403 … Permission to owner/repo.git denied`.
- **Lifetime.** Not stated. **Raw token in the orb:** a short-lived one, in memory, for each git command.

### GitHub Codespaces

- **Mechanism.** A first-party token. "Every time a codespace is created or restarted, it's assigned a new
  GitHub token with an automatic expiry period"
  ([security](https://docs.github.com/en/codespaces/reference/security-in-github-codespaces)). It is exposed
  as `GITHUB_TOKEN`, "a signed auth token representing the user in the codespace"
  ([env vars](https://docs.github.com/en/codespaces/developing-in-a-codespace/default-environment-variables-for-your-codespace)).
  **The raw token is in the VM.**
- **Scope.** The source repo: read/write if the user has write, otherwise read, and it auto-forks on push.
  Other repos are added through `devcontainer.json`, and "You can only authorize permissions that your
  personal account already possesses"
  ([repo access](https://docs.github.com/en/codespaces/managing-your-codespaces/managing-repository-access-for-your-codespaces)).
- **Lifetime.** No figure is published. "Every time a codespace is created or restarted, it's assigned a
  new GitHub token with an automatic expiry period", sized so you can "work in the codespace without
  needing to reauthenticate during a typical working day"
  ([security](https://docs.github.com/en/codespaces/reference/security-in-github-codespaces)). **Acts as:** the user. Codespaces is
  GitHub itself, so no app install or org app policy applies. Workroom cannot reproduce this.

### GitHub Copilot cloud agent

- It pushes to one branch only (a `copilot/` branch, or the PR's branch). It "cannot directly run `git push`
  or other Git commands". Its commits "are authored by Copilot, with the developer who assigned the issue …
  marked as the co-author". "Only users with write access to the repository can trigger" it
  ([risks and mitigations](https://docs.github.com/en/copilot/concepts/agents/cloud-agent/risks-and-mitigations)).
  "By default, the scope of Copilot's authentication token is limited to the repository where it's running"
  ([resources](https://docs.github.com/en/copilot/tutorials/cloud-agent/give-access-to-resources)).
  It is first-party, like Codespaces.

### OpenAI Codex cloud

- A GitHub connector app. "Secrets are removed before the agent phase starts." When the agent finishes you
  see a diff, and "You can open a PR"
  ([cloud environment](https://learn.chatgpt.com/docs/environments/cloud-environment.md)). The PR is
  created from the UI, not pushed by the sandbox.
- "Codex uses short-lived, least-privilege GitHub App installation tokens for each operation and respects
  the user's existing GitHub repository permissions and branch protection rules". **(unverified)** This
  appears only as a search-engine snippet of `developers.openai.com/codex/enterprise`, which now redirects
  to a page that does not contain it.
- Press reports of a BeyondTrust disclosure say the setup container cloned with "a GitHub OAuth token
  embedded in the git remote URL", which a branch-name injection could read
  ([SecurityWeek](https://www.securityweek.com/critical-vulnerability-in-openai-codex-allowed-github-token-compromise/)).
  **(unverified)** The primary BeyondTrust page returned 403. The lesson stands either way: a token in a
  remote URL is on disk and readable by the agent.

### Cursor cloud agents, Devin, Google Jules

- **Cursor.** A GitHub App. Setup requires "Cursor admin access and GitHub org admin access", and the App
  requests permissions including Administration
  ([GitHub integration](https://cursor.com/docs/integrations/github)). Users "need read-write privileges to
  your repo" ([cloud agents](https://cursor.com/docs/cloud-agent)). Token mechanics and identity: not found
  in primary sources.
- **Devin.** "A GitHub organization admin must install the integration". Users can link their own GitHub
  account, and an admin setting chooses whether PRs open as Devin or as the linked user
  ([GitHub integration](https://docs.devin.ai/integrations/gh)). Token storage: not documented.
- **Jules.** The "Google Labs Jules" GitHub App, with repos chosen by the user; it opens PRs
  ([FAQ](https://jules.google/docs/faq/)). Mechanics: not documented.

### Coder, Ona (Gitpod), DevPod, VS Code Remote

- **Coder.** "Coder stores your OAuth token securely in its database". The workspace's `GIT_ASKPASS` asks
  `coderd` for a token on each git operation ([external auth](https://coder.com/docs/admin/external-auth)).
  The server refreshes expired tokens, and its source notes "GitHub rotates refresh tokens on every use, so
  the old refresh token is already invalid", which is why it serialises refreshes with a database lease
  ([externalauth.go](https://github.com/coder/coder/blob/main/coderd/externalauth/externalauth.go)). This
  is the broker pattern (D) in its self-hosted form.
- **Ona.** An OAuth App requesting `repo, read:user, user:email, and workflow`, or a PAT per user. "For
  organizations you don't own, an access request will be sent to the organization owners"
  ([GitHub](https://ona.com/docs/ona/source-control/github)).
- **DevPod and VS Code Dev Containers.** They forward the local git credential helper and ssh-agent into
  the workspace ([DevPod](https://devpod.sh/docs/developing-in-workspaces/credentials),
  [VS Code](https://code.visualstudio.com/remote/advancedcontainers/sharing-git-credentials)). VS Code
  Remote-SSH documents only OpenSSH's own `ForwardAgent`
  ([troubleshooting](https://code.visualstudio.com/docs/remote/troubleshooting)); forwarding the credential
  helper over Remote-SSH is an open feature request (microsoft/vscode-remote-release #6168, #10339). No page
  says the connection must stay up. It must, by construction, which is why the design doc already rejected
  forwarding (premise 6).

### boxd.sh (the provider Workroom targets)

- **Personal connection.** "OAuth with `repo` and `user:email` scopes". Scopes mean an OAuth App, so this
  is every repo the user can reach and it is subject to org OAuth app restrictions. "A credential helper
  fetches it on demand for git operations, and `gh` gets it per call"; "Git SSH URLs … are rewritten to
  HTTPS" ([connections](https://docs.boxd.sh/guides/integrations/connections)).
- **Org connection.** "An org admin installs" the boxd GitHub App. "One installation per organization. The
  App is the team's single GitHub identity", which makes it a bot identity. `githubApp.getToken()` returns
  "a fresh installation token (about an hour, minted per call)". Shared org machines use it "instead of
  anyone's personal grant" ([connections](https://docs.boxd.sh/guides/integrations/connections)).
- **"The token never enters a machine" is contradicted by boxd's own skill doc.** On a normal machine, the
  skill says, credentials arrive "through the in-VM metadata endpoint and short-lived on-disk caches
  (`/run/boxd/*-token`, owner-readable, 5-minute TTL) — so *any code you run in that machine* can use them".
  `--isolated` removes both the endpoint and the tokens (vendor skill file
  `~/.claude/skills/boxd-cli/SKILL.md`, "Integrations"; not a public URL). Sharing a machine switches its
  token to the org App (same file). The public docs confirm the concept but not the path: `--isolated`
  strips "the in-VM `boxd` CLI, your connected integrations, your saved agent logins, and the bridge to your
  laptop" ([commands](https://docs.boxd.sh/cli/commands)), and on sharing "the machine's GitHub access also
  switches from your personal token to the organization's GitHub App token"
  ([share a VM](https://docs.boxd.sh/guides/share-a-vm)).
- **Revocation.** "Removing repo access revokes the grant at GitHub, and running machines lose access on
  their next git operation". This is account-wide, not per machine.
- So the design doc's "live candidate" (`remote-workrooms.md` item 4) is narrower than it looked. For a
  personal machine it means a broad OAuth token. For the App it means an org owner install and a bot
  author.

### exe.dev (added 2026-09-27)

exe.dev sells persistent Linux VMs reached over ssh (`ssh exe.dev`), with an ssh and HTTPS API
([what is exe.dev](https://exe.dev/docs/what-is-exe.md), [HTTPS API](https://exe.dev/docs/https-api.md)).
It is already a credential broker of the kind option D describes, run by the provider.

- **Mechanism.** The exe.dev GitHub App "will need to be installed into your account or into your
  organization". The user then creates **one integration per repository** and attaches it to VMs:
  `integrations add github --name blog --repository ghuser/blog --attach vm:my-vm`. The VM clones from
  `https://github.int.exe.xyz/ghuser/blog.git`, and `gh` works with `GH_HOST=github.int.exe.xyz`
  ([GitHub integration](https://exe.dev/docs/integrations-github.md)).
- **Where it lives.** "The secret is stored server-side and injected at the network edge when your VM calls
  the integration hostname. The VM — and any agent running on it — can *use* the integration but can never
  read the secret" ([integrations](https://exe.dev/docs/integrations.md#where-secrets-live)). So this is
  Anthropic's proxy shape, not boxd's on-disk cache.
- **Scope and lifetime.** One repo per integration. `--readonly` rejects `git push` and write API calls.
  `--for 2h` "time-box[es] every --attach to a duration from now; access lapses automatically". Everything
  is scriptable over ssh or HTTPS: `integrations add`, `attach`, `detach` and `remove`
  ([CLI](https://exe.dev/docs/cli-integrations.md)).
- **Acts as.** By default the App: "pushes show up as `exe-dev-github-integration[bot]`". `--act-as-user`
  authenticates "as your GitHub user instead", which is "Not available on team integrations"
  ([GitHub integration](https://exe.dev/docs/integrations-github.md)).
- **Non-admin.** The same App-install rule as every GitHub App: someone who can install it on the org has
  to do so once. The docs do not describe a writer-request flow.
- **Machine identity (relevant to a Workroom broker).** Identity Federation lets "an attached VM mint
  short-lived exe.dev OIDC tokens" from `https://<integration>.int.exe.xyz/token`, which AWS and GCP trust
  as an OIDC issuer ([AWS WIF](https://exe.dev/docs/integrations-aws-wif.md)). The issuer is per exe.dev
  user or team and the subject is per integration, not per VM. The docs set it up in the web UI only. A
  broker could trust the same issuer, so an exe.dev VM could prove who it is with no enrolment secret. It
  would need one integration per workroom to tell workrooms apart, and whether that can be scripted is
  **not found in primary sources**.
- **Copies (OQ10).** `cp <source-vm>` copies a VM and copies its tags by default (`--copy-tags`)
  ([cp](https://exe.dev/docs/cli-cp.md)). An integration attached with `tag:` reaches "any VM with the
  tag" ([attaching](https://exe.dev/docs/integrations-attach.md)), so a copy inherits it. Attach
  per-workroom credentials with `vm:`. Whether a `vm:` attachment follows a copy is **not found in primary
  sources**.
- **git config.** The docs use a separate hostname rather than rewriting `github.com`, and say nothing of
  a system credential helper or `insteadOf` like boxd's. Whether the stock image sets one is **not found in
  primary sources**; check it on a real VM.

### Other providers (added 2026-09-27)

Checked against each provider's own docs or published source for what a broker needs from a driver. "Not
found" means the primary sources say nothing, not that the feature is absent.

| Provider | Native GitHub credential | Stock git helper or rewrite | Machine identity, no shared secret | Fork or snapshot carries memory | Outbound HTTPS |
|---|---|---|---|---|---|
| boxd | OAuth token or org App, on-VM cache | **Yes**: system helper and `insteadOf` | Not found | Yes (live fork) | Open |
| exe.dev | Per-repo App proxy, edge-injected | No ([exeuntu](https://github.com/boldsoftware/exeuntu)) | Per integration ([WIF](https://exe.dev/docs/integrations-aws-wif.md)) | Copy (`cp`) | Open |
| E2B | Bring your own; generic edge-injected secrets ([secrets](https://docs.e2b.dev/secrets.md)) | No | **Per sandbox execution**, SPIFFE subject ([workload identity](https://docs.e2b.dev/iam/workload-identity.md)) | Yes ([snapshots](https://docs.e2b.dev/sandbox/snapshots.md)) | Open ([internet access](https://docs.e2b.dev/network/internet-access.md)) |
| Daytona | PAT per operation ([git](https://www.daytona.io/docs/en/git-operations.md)) | No | None: API keys reach every sandbox in the org ([API keys](https://www.daytona.io/docs/en/api-keys.md)) | Yes ([sandboxes](https://www.daytona.io/docs/en/sandboxes.md)) | **Restricted on tiers 1–2** ([limits](https://www.daytona.io/docs/en/network-limits.md)) |
| Morph Cloud | Not found | No | Not found | Yes ([snapshots](https://cloud.morph.so/docs/documentation/instances/creating-snapshot)) | Not found |
| Freestyle | Generic edge TLS injection; you bring the App ([guide](https://www.freestyle.sh/docs/guides/use-private-git-repositories-in-a-sandbox)) | No | Not found | Yes ([snapshots](https://www.freestyle.sh/docs/vms/base-snapshots)) | **Closed by default** ([firewall](https://www.freestyle.sh/docs/vms/network/firewall)) |
| Fly Machines | Not found | No | **Per machine**, OIDC from `/.fly/api` ([OIDC](https://docs.fly.io/reference/openid-connect/)) | Suspend keeps memory; `clone` gets an empty volume ([clone](https://docs.fly.io/flyctl/machine-clone/)) | Open until a policy exists (inferred) |
| Fly Sprites | Not found | No | Not found | Disk only ([sprites](https://docs.fly.io/sprites/working-with-sprites/)) | Open ([networking](https://docs.fly.io/sprites/concepts/networking/)) |
| Modal Sandboxes | Env-var secrets | No | **Per container**, opt-in for sandboxes ([OIDC](https://modal.com/docs/guide/oidc-integration.md)) | Yes, multi-fork ([snapshots](https://modal.com/docs/guide/sandbox-snapshots.md)) | Open ([networking](https://modal.com/docs/guide/sandbox-networking.md)) |
| Cloudflare Containers | PAT in URL ([git](https://developers.cloudflare.com/sandbox/guides/git-workflows/)); generic egress injection | No | Not found | No fork or snapshot yet ([FAQ](https://developers.cloudflare.com/containers/faq/)) | Open; interception is opt-in ([egress](https://github.com/cloudflare/containers/blob/main/docs/egress.md)) |
| Vercel Sandbox | Bring your own; firewall can inject ([firewall](https://vercel.com/docs/sandbox/concepts/firewall)) | Not found (search partly rate-limited) | Only on proxied requests (`vercel-sandbox-oidc-token`) | From last saved snapshot, **inherits env vars** ([changelog](https://vercel.com/changelog/vercel-sandbox-supports-forking)) | Open |
| Namespace | CI checkout action only | `insteadOf` only inside that CI action | Per tenant, too coarse ([federation](https://namespace.so/docs/federation/index.md)) | Not found | Not found |
| Runloop | PAT at creation, cached 1 h ([code mounts](https://docs.runloop.ai/docs/devboxes/mounts/code-mounts)) | No standing one | Not found | Disk only ([snapshots](https://docs.runloop.ai/docs/devboxes/snapshots)) | Open ([policies](https://docs.runloop.ai/docs/network-policies)) |
| Hetzner Cloud | None | None (stock cloud images) | **None**: unsigned metadata ([cloud-init source](https://raw.githubusercontent.com/canonical/cloud-init/main/cloudinit/sources/DataSourceHetzner.py)) | Disk only ([snapshots](https://docs.hetzner.com/cloud/servers/getting-started/taking-snapshots/)) | Open ([firewall FAQ](https://docs.hetzner.com/cloud/firewalls/faq/)) |

What it means for the broker:

- **Only boxd rewrites git config.** Every other provider checked ships no system helper or `insteadOf`, so
  the reset in open point 6 is boxd-specific but harmless to apply everywhere.
- **Outbound is a driver trait.** Freestyle is closed until a firewall rule opens it at creation, and
  Daytona's lower tiers are restricted. A driver must open egress to the broker's hostname, or declare it
  cannot host a workroom.
- **Machine identity is an optional driver trait, not the portable path.** E2B, Modal and Fly issue OIDC
  tokens with a per-instance subject, so on those a broker could accept the provider's token in place of
  the enrolment code. exe.dev's is per integration and Namespace's per tenant. Daytona and Hetzner have
  none. The enrolment code works everywhere, so it stays the default.
- **Every fork copies whatever the base has, in memory or on disk.** Vercel's forks also inherit
  environment variables. So the base must never enrol, and the agent must generate its key after the
  derive and bind it to the workroom's ID, refusing any key it finds that was made for another workroom.
- **Several providers already broker credentials at the edge** (exe.dev, Freestyle, Vercel, Cloudflare,
  E2B, Daytona). None of them does it for GitHub on a user's behalf except exe.dev, and using any of them
  would split the design per provider.

Unverified in this table: Morph's branching and outbound defaults;
whether Fly `clone` carries secrets; Fly's outbound default (inferred); Namespace's fork and outbound
behaviour; CodeSandbox, whose docs returned 403; Vercel's image search, which was partly rate-limited.

## GitHub primitives

| Primitive | Who must approve | Lifetime | Scope | Acts as | Source |
|---|---|---|---|---|---|
| Deploy key (write) | Repo admin, every key; orgs on Enterprise Cloud can disable deploy keys | No expiry | One repo. Also: "Deploy keys with write access can perform the same actions as an organization member with admin access" | The key, not a user | [managing deploy keys](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/managing-deploy-keys), [policy changelog](https://github.blog/changelog/2024-10-23-repository-deploy-keys-are-controlled-by-enterprise-and-organization-policy-ga/) |
| App installation token | Org owner installs; a repo admin may if the App requests no org permissions and not Administration | 1 hour | Down-scopable at mint time with `repositories` and `permissions` | "the app as a GitHub App bot account" | [installation token](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-an-installation-access-token-for-a-github-app), [installing](https://docs.github.com/en/apps/using-github-apps/installing-a-github-app-from-a-third-party), [differences](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/differences-between-github-apps-and-oauth-apps) |
| App user access token | Install as above, plus the user authorizes | 8 h; refresh token 6 months, single-use | "only do things that both you and the app have permission to do" | The user, with the App badge | [on behalf of a user](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-with-a-github-app-on-behalf-of-a-user), [refreshing](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/refreshing-user-access-tokens) |
| Fine-grained PAT | Org owner approval, which "is the default value"; the org may also block PATs | Org default maximum 366 days | One resource owner, optionally selected repos | The user | [PAT policy](https://docs.github.com/en/organizations/managing-programmatic-access-to-your-organization/setting-a-personal-access-token-policy-for-your-organization), [managing PATs](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens) |
| Machine user | Org owner adds it; it consumes a seat | Whatever its key or PAT has | Whatever it is granted | A bot user | [ToS](https://docs.github.com/en/site-policy/github-terms/github-terms-of-service), [licenses](https://docs.github.com/en/billing/reference/github-license-users) |

The details that decide the design:

- **Installation tokens need the App's private key.** You "generate a JSON Web Token (JWT) to authenticate
  as an app or generate an installation access token"
  ([JWT](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-a-json-web-token-jwt-for-a-github-app)).
  Because the tokens last 1 hour, something that holds that org-wide key must be awake at least hourly.
  GitHub advises against embedding the key in apps
  ([private keys](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/managing-private-keys-for-github-apps)).
- **User tokens need no secret if they come from the device flow.** The device flow is for apps that are
  "headless or [do] not have access to a browser", and polling needs only the `client_id`
  ([user token](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-a-user-access-token-for-a-github-app)).
  When refreshing, `client_secret` is "Required unless the user access token was generated using the device
  flow" ([refreshing](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/refreshing-user-access-tokens)).
  **So a VM can refresh its own user token forever with no Workroom secret.**
- **Refresh tokens rotate.** "Once you use a refresh token, that refresh token and the old user access
  token will no longer work" ([refreshing](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/refreshing-user-access-tokens)).
  One authorization is one chain with one holder, so a chain cannot be copied into several VMs.
- **Revoking a single user token is an App-owner operation.** "OAuth or GitHub application owners can
  revoke a single token" ([REST](https://docs.github.com/en/rest/apps/oauth-applications)). A secretless
  client cannot revoke one workroom's token. An installation token, by contrast, can revoke itself
  (`DELETE /installation/token`, [REST](https://docs.github.com/en/rest/apps/installations)).
- **User tokens can be narrowed** with `POST /applications/{client_id}/token/scoped`, "to create a
  repository-scoped and/or permission-scoped user access token"
  ([REST](https://docs.github.com/en/rest/apps/apps#create-a-scoped-access-token)). Whether this needs the
  client secret, as the neighbouring App-owner endpoints do, did not show in the fetched page
  **(unverified)**.
- **Org policy.** OAuth app access restrictions are "enabled by default" for new orgs
  ([OAuth restrictions](https://docs.github.com/en/organizations/managing-oauth-access-to-your-organizations-data/about-oauth-app-access-restrictions)).
  GitHub Apps are "not subject to organization application policies"
  ([differences](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/differences-between-github-apps-and-oauth-apps)).
  Under SAML SSO, "You must have an active SSO session each time you authorize an OAuth app or GitHub App"
  ([SSO](https://docs.github.com/en/enterprise-cloud@latest/authentication/authenticating-with-single-sign-on/about-authentication-with-single-sign-on)).
  Whether a refresh also needs an active SAML session: not found.
- **Machine users.** "A machine account is an Account set up by an individual human who accepts the Terms
  on behalf of the Account … and is responsible for its actions", and you may keep "no more than one free
  machine account" ([ToS](https://docs.github.com/en/site-policy/github-terms/github-terms-of-service)).
  In an org it is a member or collaborator, so it takes a seat
  ([licenses](https://docs.github.com/en/billing/reference/github-license-users)). App bots "do not consume
  a GitHub Enterprise seat" ([differences](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/differences-between-github-apps-and-oauth-apps)).
- **Attribution and protection.** On every HTTPS option the commit author is whatever the VM's git config
  says, and the pusher is the token's identity. Rulesets can let GitHub Apps bypass; the fetched page did
  not list deploy keys as bypass actors (not found, rather than confirmed absent)
  ([rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/creating-rulesets-for-a-repository)).
  Secret-scanning push protection covers command-line pushes, but the docs do not distinguish by credential
  type ([push protection](https://docs.github.com/en/code-security/secret-scanning/introduction/about-push-protection)).
  Any token pushed to a public repo "will be automatically revoked"
  ([revocation](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/token-expiration-and-revocation)).

**Added 2026-09-27, for the broker (option D).**

- **The token cap is documented for OAuth apps only.** Under the heading "Token revoked due to excess of
  tokens for an OAuth app with the same scope": "There is a limit of ten tokens that are issued per
  user/application/scope combination, and a rate limit of ten tokens created per hour." Past the cap GitHub
  revokes the oldest unused, then least recently used, token. Past the rate limit it "will trigger a
  re-authorization prompt within the browser"
  ([revocation](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/token-expiration-and-revocation)).
  Nothing says whether GitHub App user tokens share it. This is why OQ20 mints installation tokens for git.
- **Scoped user tokens** need Basic authentication with the client ID and secret (checked on a mirror of the
  REST page, lower confidence) and return an `expires_at`. The docs do not say whether that expiry follows
  the parent token ([REST](https://docs.github.com/en/rest/apps/apps#create-a-scoped-access-token)). No
  longer load-bearing: the broker holds the secret and does not use this endpoint for git.
- **User-token expiry is optional**, and "GitHub recommends that you opt in to this feature for improved
  security". With it off, refresh tokens are omitted
  ([refreshing](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/refreshing-user-access-tokens)).
- **Revoking one token.** `DELETE /applications/{client_id}/token` takes `access_token` and needs Basic
  authentication with the client ID and secret. `DELETE /applications/{client_id}/grant` "will also delete
  all OAuth tokens associated with the application for the user"
  ([REST](https://docs.github.com/en/rest/apps/oauth-applications#delete-an-app-token)).
- **Install and request.** "Repository admins can install GitHub Apps in the organization that owns the
  repository if the app does not request any organization permissions nor the 'repository administration'
  permission" ([installing](https://docs.github.com/en/apps/using-github-apps/installing-a-github-app-from-a-third-party)).
  A member who cannot install can request it, and "GitHub will send an email to the organization owner"
  ([requesting](https://docs.github.com/en/apps/using-github-apps/requesting-a-github-app-from-your-organization-owner)).
  So the Workroom App should ask for repository permissions only, which lets a repo admin install it.
- **SAML.** "You must have an active SSO session each time you authorize an OAuth app or GitHub App in order
  to access an organization that uses or enforces SSO"
  ([SAML](https://docs.github.com/en/authentication/authenticating-with-saml-single-sign-on/about-authentication-with-saml-single-sign-on)).
  The refresh page never mentions SAML, and nothing covers use after the session ends.
- **Rate limits.** A user token uses the user's primary rate limit, and "No more than 2,000 OAuth access
  token requests per hour are allowed for GitHub Apps and OAuth apps"
  ([rate limits](https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api)). The
  page does not say whether installation-token mints count toward it. At one mint per workroom per hour it
  would matter only past about 2,000 active workrooms.
- **Attribution of user tokens.** "The GitHub UI will show the user's avatar photo along with the app's
  identicon badge"
  ([on behalf of a user](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-with-a-github-app-on-behalf-of-a-user)).
- **Pushes by an App through branch protection.** A protected branch can give push access "to users, teams,
  or installed GitHub Apps with write access to a repository"
  ([protected branches](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches)).

## Mapping to Workroom

Scored against the design doc's constraints (premises 4, 6 and 8; OQ10; Phase 0 item 4):

| | No Workroom server | Laptop closed, indefinitely | Writer, not admin | Mac stores nothing | Revoked on destroy | Minted after fork | Provider-agnostic |
|---|---|---|---|---|---|---|---|
| A deploy key | yes | yes | **no** | yes | yes | yes | yes (must defeat boxd's rewrite) |
| B App user token, chain on VM | yes | yes | yes, after a one-time owner install | yes | **no** (lingers up to 6 months unused) | yes | yes |
| B′ App user token, chain on Mac | yes | **no**: at most 8 h | yes, after install | **no** (Keychain) | token dies within 8 h | yes | yes |
| C provider credential | yes | yes | personal: unless OAuth restrictions; App: owner install | yes | **no** (account-wide) | provider-dependent | **no** |
| D Workroom broker | **no** | yes | yes, after install | yes | yes | yes | yes |
| Fine-grained PAT | yes | yes | only if the org allows PATs and approves the token | **no** | **no** | injected after fork, but shared | yes |
| Machine user | yes | yes | needs owner, plus a seat | **no** | **no** | yes | yes |
| Installation token, key on Mac or VM | yes | Mac: **no** (1 h); VM: yes | owner install | Mac: **no** | yes | yes | yes |

**A. Deploy key (the current plan).** Premise 6 holds as written. The failure is detectable only by trying:
Phase 0's addendum showed `permissions.admin` lies, so the driver attempts the `POST` and treats 403 as "use
B". It stays the narrowest credential available, one repo with a real revoke. The GitHub quote above adds a
cost the design doc did not record: a write deploy key has admin-equivalent git powers. On boxd it only
carries traffic if the agent defeats the system-level `insteadOf` (Phase 0 used `GIT_CONFIG_NOSYSTEM=1`).

**B. Workroom GitHub App, device flow on the VM.** The mechanics:

- **Registration.** Workroom's maintainer registers one public GitHub App with device flow enabled and
  user-token expiration on (the default). It requests only Contents read/write, plus Metadata. With no org
  permissions and no Administration, a *repo admin* can install it, not only an org owner. `gh` stays on the
  Mac under the user's own auth, so the App needs no PR permission. The client ID ships in the app. If a
  private key is ever generated, it is never used on this path and never leaves the maintainer. Decide at
  registration whether to add Workflows write: without it a push that edits `.github/workflows/` is
  rejected (Claude's docs flag the same gap for `gh` tokens without the `workflow` scope,
  [web quickstart](https://code.claude.com/docs/en/web-quickstart)), and adding it still leaves the App
  installable by a repo admin.
- **Per workroom, after the fork.** `wr-agent` starts a device flow and the Mac shows the code and opens
  `github.com/login/device`. The resulting token pair is written only on the VM, as an owner-only file.
  GitHub's own CLI tutorial stores it that way at `0600`
  ([tutorial](https://docs.github.com/en/apps/creating-github-apps/writing-code-for-a-github-app/building-a-cli-with-a-github-app)).
  `wr-agent` serves it to git as `credential.https://github.com.helper` and refreshes it with a single
  refresher, because rotation makes concurrent refreshes lose the chain, as Coder found.
- **Premise 6.** The Mac still stores nothing, which is the claim premise 6 kept after its revision. On the VM
  the user token takes the deploy key's place, and it is the first credential there that is *not*
  instance-scoped: a user token whose reach
  is the user's access ∩ the installation's repos, backed by a refresh token that survives destroy on
  GitHub's side until 6 months unused or until the user revokes the whole authorization. "Leaks expire by
  construction" weakens to 8 h for the access token and 6 months for the refresh token.
- **Pushes are not branch-restricted.** Anthropic enforces the branch at its proxy. Here only the repo's own
  rulesets constrain what the token can push to.
- **Non-admin.** Solved once per org, not per workroom. A writer whose org has no install sees GitHub's
  request-to-owner flow.
- **Laptop closed.** Solved: the VM refreshes itself with no secret.
- **OQ10.** Solved by construction, because the device flow runs after derivation. The rule Amp states
  applies: the token must never be in the snapshot a later fork starts from, so it must not be in the remote
  URL (the Codex incident) or on the base.
- **Provider-agnostic.** Yes. It is plain HTTPS plus a credential helper.
- **boxd.** This option works *with* boxd's rewrite rather than against it, since boxd already maps
  `git@github.com:` to HTTPS. But boxd's system-level `credential.https://github.com.helper=boxd` is
  consulted first. Git documents that setting `credential.helper` to the empty string "resets the helper
  list to empty" ([gitcredentials](https://git-scm.com/docs/gitcredentials)), which is unlike `insteadOf`,
  which Phase 0 found cannot be cleared. Whether the reset also works for the URL-scoped key at global
  scope over a system entry is a spike item, not a fact.
- **B′.** Keeping the chain on the Mac removes the per-workroom approval but caps unattended push at about
  8 h after the lid closes, and puts a refresh token in the Mac's Keychain. It breaks two constraints to fix
  one friction, so it is not recommended.

**C. Provider-supplied, as a declared trait.** This is the same shape the design doc already uses for the
lifecycle shim's control-plane credential (premise 8; OQ17 answered for boxd): the driver declares whether
it can supply a git credential and what that credential's scope is. On boxd it costs nothing to build,
because the helper is already there. What it gives: a personal machine gets the user's `repo`-scoped OAuth
token, cached readable in `/run/boxd`. That token is reachable by any code in the box, blocked by default in
orgs with OAuth restrictions on, and incompatible with `--isolated`. Shared machines get a bot identity from
an App that an org owner installed. Premise 6 holds trivially (Workroom stores nothing), but the blast radius
is the provider's to choose, and a second provider may offer nothing. Treat C as an accelerator; B remains
the portable path.

**D. A Workroom broker.** This is Coder's and Amp's architecture: a server holds the refresh token or the
App key, and `wr-agent`'s helper asks it for a short-lived token authenticated by the instance's identity.
It removes B's costs, namely per-workroom approval, the VM-held refresh token and the missing revocation.
It can narrow tokens to one repo, either with installation tokens or, if that endpoint turns out to need
the client secret, with `token/scoped`. It is a product change: Workroom would operate an always-on
service holding users' GitHub credentials. Not recommended now; it is the upgrade path if B's friction
proves unacceptable.

**Rejected.**

- **Fine-grained PAT.** No creation API, so one token is shared by every workroom on the repo. It needs org
  approval by default, lives up to 366 days, and Workroom would store it.
- **Machine user.** Owner action plus a paid seat, a long-lived secret, and a human on the hook under the
  ToS.
- **Installation tokens minted from a Workroom-held private key without a server.** On the Mac, pushes stop
  an hour after the lid closes. On the VM, an org-wide App key sits on a disposable box, which is worse than
  every other row. *(2026-09-27: the rejection is of "without a server". Under D the broker is that server,
  and installation tokens became its git credential; see OQ20.)*

**The base machine's own credential (OQ10's second half).** The base only needs *read*, once, when it is
built or refreshed, and that happens while the Mac is awake. That is a much easier problem than the
workroom's, and none of the options is hurt by it. The only rule: whatever clones the base must be used for
that one command and be gone before the first fork, and never be written into the remote URL. Amp's clone
credential "applies only to the clone command and is discarded afterwards"
([GitHub & Git](https://ampcode.com/docs/github)).

## Open points, and what a spike should measure

Status as of 2026-09-27, after the owner chose D. Each item says whether it was resolved (and how), made
moot by the decision, or still needs a spike.

1. **Per-workroom device-flow friction.** *Moot under D.* There is no per-workroom device flow: the user
   authorizes the App once, when signing in to the broker.
2. **Token caps.** *Reframed, then resolved by design.* GitHub documents the cap for OAuth apps only (see
   "Added 2026-09-27" under GitHub primitives). OQ20 mints installation tokens for git, which have no
   per-user cap, so the design no longer depends on the answer. **Spike S1** below still decides whether
   scoped user tokens could come back.
3. **Unattended refresh.** *Moot as a question.* The broker refreshes server-side. It becomes a broker test:
   a VM keeps pushing across at least two user-token refreshes (over 16 h) with the laptop closed.
4. **Org behaviour.** *Resolved from the docs, except SAML.* A repo admin can install an App that asks for
   repository permissions only, and a member who cannot install can request it, which emails the owner.
   SAML: an active SSO session is required to authorize; later use and refresh are not documented. Designed
   around rather than tested (spike S2, deferred).
5. **Narrowing and revocation without a secret.** *Moot under D.* The broker holds the client secret.
6. **boxd helper precedence.** *Resolved, measured locally on git 2.55.0.* With boxd's two lines as the
   system config and stub helpers: adding Workroom's helper at `--global` alone, boxd's still answers. An
   empty `credential.https://github.com.helper` at `--global` first resets the inherited list, and then
   Workroom's answers. (An empty bare `credential.helper` also reset it on this git version; the agent
   should reset the URL-scoped key, which does not depend on that.) boxd's `insteadOf` still rewrites
   ssh remotes, which is harmless because broker tokens use HTTPS. The fork question applied only to C.
7. **exe.dev git config and copies.** *Image resolved, copies moot.* exe.dev publishes its default image,
   [`boldsoftware/exeuntu`](https://github.com/boldsoftware/exeuntu). Its Dockerfile (commit `ae8be4d`,
   2026-09-24) sets only `git config --global init.defaultBranch main`: no credential helper and no
   `insteadOf`. It does run a per-VM first-boot script, `/exe.dev/setup` (`exe-setup.service`). That script
   is the user's own: `ssh exe.dev help new` lists `--setup-script`, "setup script to run on first boot (max
   10KiB)" (checked 2026-09-27 against a live account). So a VM created without one gets no git config from
   the platform beyond the image. Confirmed on a live VM created without one (2026-09-27, run by the owner):
   `git config --list --system` failed with `fatal: unable to read config file '/etc/gitconfig': No such
   file or directory`, so there is no system git config at all. Across every level, `git config
   --show-origin --list` showed one line: `file:/home/exedev/.gitconfig init.defaultbranch=main`.
   Whether a `vm:` attachment follows `cp` is moot, because provider integrations go unused under D.
8. **Phase 0 carry-over.** *Moot.* The deploy key is dropped, so isolating its 403 to the Administration
   permission no longer matters.
9. **Mac-to-broker authentication (new).** *Resolved: a Secure Enclave signing key*, measured on this Mac in
   a binary with no Keychain use and no entitlements, ad hoc signed and with the hardened runtime. Details in
   OQ20. Confirm in the first Nightly's Developer ID build.

**Spikes still needed.** Each needs something outside this repo, so each waits for the owner's go-ahead.

- **S1. Does the token cap apply to GitHub App user tokens?** Low priority: the design no longer depends on
  it, and it only decides whether scoped user tokens could come back. Needs a registered Workroom GitHub App
  (created in the GitHub UI; free). Mint 12 scoped tokens for one user within an hour and check whether the oldest
  stops working and whether a re-authorization prompt appears. Teardown: delete the App.
- **S2. SAML. Deferred (owner, 2026-09-27).** OQ20 keeps the authorization answer for the workroom's
  lifetime and re-checks when it can, so the design works whichever way GitHub behaves. Enforcing SAML needs
  GitHub Enterprise Cloud ("To use SAML single sign-on, your organization must use GitHub Enterprise Cloud",
  [enabling SAML](https://docs.github.com/en/enterprise-cloud@latest/organizations/managing-saml-single-sign-on-for-your-organization/enabling-and-testing-saml-single-sign-on-for-your-organization))
  plus an identity provider, so run this when a SAML user needs it. What it would do: authorize the App, let the SSO session lapse (24 h by
  default), then use and refresh the user token against an org repo, and mint and use an installation token
  there too. This one matters: the user token backs the per-mint authorization check, so if it stops working
  when the session lapses, pushes stop after a day on such orgs (OQ20 records the fallback).
- ~~**S3. exe.dev first-boot script.**~~ Done (open point 7): the script is the user's own
  `--setup-script`, and a live VM has no `/etc/gitconfig`.

**Unverified claims in this note:**

- Codex's "short-lived, least-privilege GitHub App installation tokens": not on any OpenAI docs page checked;
  only a secondary paraphrase. `help.openai.com/en/articles/20001107-codex-security` returned 403 twice.
- The Codex setup container holding an OAuth token in the git remote URL: press reports only. BeyondTrust's
  page returned 403 and a CAPTCHA, and no first-party OpenAI statement was found.
- The ten-token cap applying to GitHub App user tokens (spike S1).
- Whether `token/scoped` needs the client secret (checked on a mirror only; no longer load-bearing).
- SAML behaviour after authorization (spike S2).
- That DevPod and VS Code forwarding stops when the connection drops (inherent to forwarding, not stated).
- boxd's `/run/boxd` path and "metadata endpoint" come from a vendor skill file. The public docs confirm
  that agent logins and integrations reach the machine unless it is `--isolated`.
- Claude cloud sessions refreshing tokens server-side (inferred from the 72-hour routine window).
- exe.dev: whether Identity Federation
  integrations can be created from the CLI (the docs show the web UI only).
