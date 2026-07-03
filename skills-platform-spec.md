# Altr — Full Product Specification v1.0

> **Altr** (altr.run) — a shared library where a team creates, versions, and syncs AI agent skills across every tool they use — Claude Code, Claude.ai, Cursor, OpenAI Codex, ChatGPT — with zero Git knowledge required. A skill *alters* how your agent behaves; `.run` because agents run skills.
>
> **Tagline:** *GitHub for your team's AI skills, without the Git.*
>
> Date: 2026-07-03 · Owner: Mukul Chugh · Status: Spec for build (v0 validation → v1 platform)

---

## Table of contents

1. [Thesis & positioning](#1-thesis--positioning)
2. [Market context](#2-market-context-verified-2026-07-03)
3. [Personas & jobs-to-be-done](#3-personas--jobs-to-be-done)
4. [Domain model & glossary](#4-domain-model--glossary)
5. [Product principles](#5-product-principles)
6. [Feature scope by phase](#6-feature-scope-by-phase)
7. [User flows](#7-user-flows)
8. [The AI-authoring engine](#8-the-ai-authoring-engine)
9. [Architecture](#9-architecture)
10. [Data model](#10-data-model)
11. [Interfaces: MCP, CLI, API](#11-interfaces-mcp-cli-api)
12. [Sync protocol & integrations](#12-sync-protocol--integrations)
13. [Auth & authorization](#13-auth--authorization)
14. [Security & privacy](#14-security--privacy)
15. [Non-functional requirements](#15-non-functional-requirements)
16. [Pricing & packaging](#16-pricing--packaging)
17. [Go-to-market & growth](#17-go-to-market--growth)
18. [Success metrics](#18-success-metrics)
19. [Risks & tripwires](#19-risks--tripwires)
20. [Roadmap & build plan](#20-roadmap--build-plan)
21. [Open questions](#21-open-questions)
22. [Appendix: sources](#appendix-a--sources)

---

## 1. Thesis & positioning

**The one-liner:** Altr is a shared library where a team creates, versions, and syncs AI agent skills across every tool they use, without anyone touching Git.

**The five load-bearing beliefs (from verified research):**

1. **The format war is over — build ON the standard.** Agent Skills is an open, multi-vendor standard (a folder with `SKILL.md`, adopted by 42+ tools including OpenAI Codex, Cursor, GitHub Copilot, Gemini CLI). Inventing a proprietary format would be strategic suicide. Altr stores and emits spec-compliant skills, always.
2. **The gap is distribution, not format.** Today's distribution is Git/CLI-based and developer-only (`npx skills add`, plugin marketplaces). No product combines Git-free versioning + non-technical UX + cross-vendor sync.
3. **Cross-vendor neutrality is the durable wedge.** Anthropic will sync skills across Claude surfaces; OpenAI across theirs. Neither has an incentive to sync *between* ecosystems. That Switzerland position is what a platform vendor won't build.
4. **AI-authoring is the unlock.** Non-technical users don't hand-write YAML+markdown. "Describe it → AI writes a spec-compliant skill" is what makes the library usable by the buyer persona.
5. **You pay for the team layer, not the format.** Versioning is table-stakes (competitors give it away). The paid surface is private libraries, roles, approvals, and cross-tool sync.

**Positioning against adjacent tools:**

| Category | Example | Why not a direct competitor |
|---|---|---|
| Skill CLIs / marketplaces | vercel-labs `skills`, Netresearch marketplace | Developer-only, Git/CLI, no team UX or non-technical authoring |
| Prompt management | PromptHub, PromptLayer | Prompt/API-ops for engineers; not agent skills, not cross-tool sync |
| LLM observability | Langfuse, Latitude | Eval/tracing for people building products — different buyer |
| AI governance / DLP | TeamPrompt | Compliance + prompt library for chat tools; no versioning or portable format |
| Platform-native | Anthropic org skills, GPT Store | Single-vendor; the exact thing our neutrality routes around |

**Non-goals (explicit):** prompt observability/evals, LLM DLP/compliance, a public skills marketplace, building an agent runtime, inventing a skill format.

---

## 2. Market context (verified 2026-07-03)

- **Open standard exists.** Anthropic published Agent Skills as an open standard on **Dec 18, 2025** (agentskills.io; spec at github.com/agentskills/agentskills). A skill = a directory with a `SKILL.md` (YAML frontmatter, only `name` + `description` required) plus markdown instructions and optional `scripts/`, `references/`, `assets/`. Loaded via progressive disclosure. Nothing requires Git.
- **Cross-vendor adoption is real.** 42+ tools document the format, including competitors: OpenAI Codex ("build on the open agent skills standard"), Cursor, GitHub Copilot, VS Code, Gemini CLI, JetBrains Junie, Snowflake Cortex, Databricks.
- **Governance is consolidating.** On **Dec 9, 2025**, OpenAI, Anthropic, and Block co-founded the **Agentic AI Foundation** under the Linux Foundation (AGENTS.md, MCP, goose donated). Two complementary standards now matter: **Agent Skills** (packaged skills) and **AGENTS.md** (project instructions).
- **Distribution today is developer-only.** `npx skills add <repo>` (installs into 70+ detected tools), Claude Code plugin marketplaces (a marketplace = a Git repo), curated GitHub collections.
- **Portability today ≠ sync.** The same skill must be *separately* installed on each surface (Claude Code plugin vs. Claude.ai upload vs. API). Format compatibility exists; a **unified sync mechanism does not**. This is simultaneously the opportunity and the feature Anthropic is likeliest to ship next.
- **Pricing anchor.** PromptHub: free tier (public prompts only), Team **$20/user/mo** monthly / **$15** annual; versioning included in *all* tiers → versioning is table-stakes.

**Biggest risk:** Anthropic explicitly plans "the full lifecycle of creating, editing, discovering, sharing, and using Skills" and already shipped org-wide admin skill deployment (Dec 2025). See §19.

**Honest caveat:** direct demand evidence (forum complaints, willingness-to-pay) was *not* established by research — the gap is inferred from competitor absence. The v0 validation gate (§20) exists to close this.

---

## 3. Personas & jobs-to-be-done

| Persona | Profile | Primary tools | Pain | Job-to-be-done |
|---|---|---|---|---|
| **Maya — Ops lead** *(buyer/champion)* | Non-technical | Claude.ai, ChatGPT | The team's best prompts/SOPs live in a Google Doc; everyone pastes stale copies | "When I improve how we handle X, make that improvement available to the whole team instantly, everywhere they work — without me learning Git." |
| **Dev — Senior engineer** *(adopter)* | Technical | Claude Code, Cursor, Codex | Wrote great skills; sharing means "clone this repo" and non-devs never do | "Let me keep my Git workflow, but have teammates' improvements flow to me and mine flow to them without me babysitting a repo." |
| **Priya — Team lead** *(economic buyer)* | Semi-technical | Both | No single source of truth; no review before a skill goes team-wide | "Give me one library, control over who can change what, and a review gate before a skill ships to everyone." |

**Target customer:** teams of **5–50** where engineers use agentic coding tools AND non-engineers use chat tools. **Beachhead:** AI-forward startups and agencies. **Bridge team** (the wedge): a team with both a non-technical editor and a Git-path engineer active in the same library.

---

## 4. Domain model & glossary

- **Skill** — a spec-compliant Agent Skills folder: `SKILL.md` (YAML frontmatter: `name` ≤64 chars lowercase-hyphen, `description` ≤1024 chars) + markdown instructions + optional `scripts/`, `references/`, `assets/`. Altr never stores skills in a proprietary shape; **the folder IS the record.**
- **Library** — a team workspace holding skills. Backed **1:1 by a real Git repository** (invisible to non-technical users, cloneable by engineers).
- **Version** — a Git commit, surfaced as a human list: *"v4 · Maya · yesterday · 'added refund edge case'"* with one-click restore and prose diff.
- **Channel** — `draft` → `in_review` → `published`. Only `published` versions sync. The `in_review` gate is optional (paid).
- **Target** — a sync destination: `marketplace` (Claude Code), `agent` (local disk for Cursor/Codex), `export` (Claude.ai zip / ChatGPT text / AGENTS.md).
- **Sync agent** — a small Go menu-bar daemon that pulls published skills into local tool directories.
- **Meta-skill** — Altr delivered *as a skill/MCP* inside Claude Code/Claude.ai: "the skill that writes skills" (v0 authoring surface).
- **Bridge team** — the north-star cohort (see §3, §18).

---

## 5. Product principles

1. **Standards-native or nothing.** Every stored and emitted artifact is a valid Agent Skill. Portability is guaranteed by construction, not by a converter.
2. **Git is the engine, invisible to the buyer.** Every save is a commit; non-technical users never see a branch, a merge, or a diff patch. Engineers get a real cloneable remote.
3. **No lock-in, as a feature.** The repo is the source of truth; the database is a rebuildable index. Users can walk away with their skills anytime — this is a trust requirement for the dev persona.
4. **AI does the writing.** The default authoring path is describe-intent → generate, not type-markdown.
5. **Serve the buyer, ride with the adopter.** The web app exists for Maya; the CLI/Git path exists for Dev. Same library underneath.
6. **Boring infrastructure.** Next.js, Supabase, a git host's API, Stripe. Novelty budget goes to the authoring + sync spine, nowhere else.
7. **Ship v0 without the web app.** Prove the loop as a meta-skill/MCP before building a dashboard.

---

## 6. Feature scope by phase

**AI-authoring is the core interaction, not a garnish.** The primary way skills come into being: *describe intent in plain language → Altr generates a spec-compliant skill*; or *select an existing skill → "improve / tighten / add an edge case."*

### Phase v0 — no web app (validate the loop cheaply, ~2–3 weeks)
- **Meta-skill + MCP server** — in Claude Code or Claude.ai: *"make me a skill that does X"* → Altr generates the skill, commits it to the user's git-backed library, syncs it out.
- **AI-authoring engine** — generate + improve (see §8).
- **Git-backed versioning** behind the scenes (via git host API).
- **Claude Code marketplace endpoint** — library = plugin-marketplace URL.
- **`altr` CLI** — auth, list, pull, push, sync.
- Management via CLI + the git host's own web view.
- **Gate:** does create → version → sync hold with 10–15 design partners before building a dashboard?

### Phase v1 — the web app platform (serve the buyer, ~6 weeks)
- **AI-generate panel** (same engine as v0) + rich markdown editor, live preview, spec validation
- **Versioning UI** — history list, prose diff, one-click restore
- **Import** — GitHub repo scan, folder/zip upload, raw-prompt → AI-scaffold
- **Sync** — marketplace endpoint + macOS sync agent (Cursor, Codex, Claude Code local) + Claude.ai/ChatGPT export
- **Library & skill management**, teams, roles (Admin/Editor/Viewer), email invites
- **Auth** — Auth.js (Google OAuth + email magic links)
- **Playground** — test a skill against a model
- **Billing** — Free/Team (Stripe)

### V1.1 — fast follows
- Approval workflow (`in_review` gate); activity feed; pull-count analytics
- Windows/Linux sync agent; `altr` CLI in CI
- Public/unlisted skill sharing links (growth loop)
- Connect-your-own git host (GitHub/GitLab/Bitbucket) beyond Altr-hosted
- Prompt library (lightweight prompts alongside skills)
- AGENTS.md export

### V2 — skill marketplace (needs users first)
- **Curated + community-submission marketplace** — discover and one-click-add skills to your library. A growth/content asset (per-skill SEO, sharing loop), *not* a head-to-head with vendor in-app marketplaces.
- **Skill Curator** role — review/feature submitted skills, maintain curated collections.
- Sequenced after the core sync loop proves out — an empty store is worse than none.

### Later — explicitly deferred
- Two-way sync from local edits (drift → PR-like proposal)
- Skill analytics from agent telemetry; A/B versions
- Enterprise: SAML/SSO, SCIM, audit log, self-hosting

### Never
- Proprietary skill format · agent runtime · prompt-eval platform · being a thin model reseller

---

## 7. User flows

### 7.1 Onboarding — target < 10 min to first synced skill
1. Sign up (Google or magic link) → create Library ("Acme Team") → invite via email link.
2. Seed the library one of three ways:
   - **Import** a GitHub repo URL (scan for `SKILL.md` folders), or upload a folder/zip.
   - **Generate** — "Describe a skill you want" → AI scaffolds the first one.
   - **Start empty.**
3. Connect first target:
   - Claude Code: one-liner `claude plugin marketplace add acme.altr.run` (zero client software).
   - Cursor/Codex: install the sync agent (`brew install altr` or download).
4. First skill appears in the tool. Done.

### 7.2 Maya creates a skill (non-technical, AI-first)
1. **New Skill → "What should the AI be able to do?"** She types plain language: *"Draft refund replies in our brand voice, always offer a discount code before a refund, escalate anything over $200."*
2. Altr generates a spec-compliant skill: `name`, `description` ("when to use this"), structured instructions, and — if she attached examples — a `references/` file. She reviews in **plain prose**, never YAML.
3. **"Improve"** — she can ask for changes conversationally ("also mention our 30-day policy").
4. **"Test it"** — the playground runs the skill against a sample task so she sees behavior before publishing.
5. **Publish** (or **Request review** if approvals are on) → syncs to all connected targets. She never saw Git, YAML, or a terminal.

### 7.3 Dev edits from the terminal (technical)
1. `git clone git@altr.run:acme/skills.git` — the library is a plain repo (or a GitHub repo if that backend is used).
2. Edit `SKILL.md`, commit, push. A push hook validates against the spec and rejects broken frontmatter with a clear message.
3. His push appears in the web UI as a new version; Maya sees *"Dev updated code-review-checklist"* and can read the diff as prose.
4. **Conflicts:** last-write-wins per skill with full history (restore anything). True Git merge is available to Git users. No merge UI for non-technical users in v1.

### 7.4 Skill consumption — the sync fan-out
- **Claude Code:** library = plugin-marketplace URL; team adds once, updates flow on normal refresh. No client software.
- **Cursor / Codex / local-disk tools:** sync agent pulls published skills into each tool's directory (`~/.cursor/skills`, `~/.codex/skills`, …), reusing the `skills` CLI's tool-detection map. **Pull-only in v1**; local edits are flagged "drifted," not pushed.
- **Claude.ai:** "Download for Claude.ai" zip + step-by-step upload helper (no org-upload API at research date; wire it the moment Anthropic exposes one).
- **ChatGPT / GPTs:** export skill as a system-instruction text block with copy button (instructions carry over; scripts degrade gracefully).
- **AGENTS.md:** per-repo export composing an `AGENTS.md` from selected skills, for tools that consume that standard.

### 7.5 Governance (paid)
- Roles: **Admin / Editor / Viewer.**
- Optional approval workflow: Editors submit → Admins approve → publish.
- Activity feed + per-skill usage signal (v1.1: sync-pull counts; later: opt-in agent telemetry).

---

## 8. The AI-authoring engine

The feature that makes the product usable by non-writers. Three capabilities, all producing/validating spec-compliant output.

### 8.1 Generate (intent → skill)
- **Input:** plain-language description of desired behavior, optional pasted examples/docs.
- **Process:** a system prompt instructs the model to emit a valid Agent Skill — a `name` (lowercase-hyphen, ≤64), a `description` phrased as *when to use it* (≤1024, the field agents match on), and structured markdown instructions. Attached examples become `references/` files; the model is told to keep `SKILL.md` lean and push detail into references (progressive disclosure).
- **Output:** a full skill folder, validated (§8.4) before it's shown or committed.

### 8.2 Improve (skill → better skill)
- Conversational edits ("add an edge case", "tighten the tone", "split this into two skills"), operating on the current version and producing a new commit.
- **Description-quality pass:** the `description` is what determines whether an agent invokes the skill at the right time — the engine specifically critiques and sharpens it (specific triggers, no vague verbs).

### 8.3 Lint / review
- On save and on demand: checks spec compliance, description specificity, instruction clarity, and flags secrets or environment-specific paths that shouldn't be shared.

### 8.4 Validation (the boundary guarantee)
- Every AI output AND every human/Git edit passes the same validator (mirrors `skills-ref validate` semantics): frontmatter present and within limits, `name` pattern valid, referenced files exist, no oversized `SKILL.md`. Invalid skills never get committed. This is what makes "portable by construction" true.

### 8.5 Models & BYOK
- **BYOK is the universal default** — customers already have model keys.
- **OpenRouter is the managed gateway.** One API fronts Claude + Gemini + GPT, so the managed quota is multi-model and cost-efficient, and BYOK users can bring an OpenRouter key or a native provider key. The engine is model-agnostic behind this adapter.
- **Paid tiers bundle a capped managed-model quota** (e.g. N generate/improve/playground runs per seat per month) so non-technical users get zero-config authoring without ever touching an API key. Not sold as a standalone model SKU — friction removal priced into the seat. Quota capped to bound cost.
- Default model: latest Claude via OpenRouter.

---

## 9. Architecture

```
┌──────── Web app + API (Next.js on Vercel) ─────────┐
│  AI-generate · Editor · History/Diff · Playground  │
│  · Admin — server actions / route handlers         │
│  · Auth.js (Google OAuth + email magic links)      │
│  · Skill service — validate, commit, publish       │
│  · Authz enforced in server layer (no RLS reliance)│
└──────┬────────────────┬──────────────┬─────────────┘
       │                │              │
┌──────▼──────┐  ┌──────▼──────┐  ┌────▼──────────────┐
│  Supabase   │  │ Git backend │  │ Serve layer       │
│  Postgres — │  │ 1 repo/lib  │  │ · /marketplace/:  │
│  metadata + │  │ GitHub-API  │  │   lib → Claude    │
│  Auth.js    │  │ OR small    │  │   Code plugin mkt │
│  adapter    │  │ Gitea box   │  │ · /sync/:lib →    │
│  tables;    │  │ (cloneable  │  │   hash manifest   │
│  Storage    │  │  remote)    │  └────┬──────────────┘
│  for assets │  └─────────────┘       │ HTTPS pull
└─────────────┘                 ┌──────▼──────────────┐
                                │ Sync agent (Go,     │
                                │ menu bar) → writes  │
                                │ ~/.cursor/skills,   │
                                │ ~/.codex/skills, …  │
    ┌──────────────────────┐   └─────────────────────┘
    │ Meta-skill + MCP      │──→ same Skill service (v0 authoring,
    │ (v0: author in-tool)  │     no web app required)
    └──────────────────────┘
```

**Load-bearing decisions**

1. **Git repo = source of truth; Supabase Postgres = metadata only.** Everything exportable, no lock-in, and the marketplace endpoint is trivial (serve files at the published ref). The DB is a rebuildable index over the repos.
2. **Git does not run on Vercel**, and Altr supports two git backends per library:
   - **Altr-hosted (default)** — for non-technical teams with no GitHub. A git host's API (GitHub org repos or a small Gitea) provides versioning, diffs, history, and a cloneable remote with zero git-ops for the user.
   - **Connect your own** — GitHub / GitLab / Bitbucket. Teams already living in a git host link an existing repo; Altr reads/writes via the provider API (OAuth app). Maximum no-lock-in, and Altr hosts nothing.
   Either way the git repo is the source of truth and the serve layer reads published files from it.
3. **Auth = Auth.js, sole system**, using the **Supabase Postgres adapter** (one database). Google OAuth + email magic links (email provider e.g. Resend). Accepted consequence: no Supabase RLS `auth.uid()`, so **authorization is enforced in the server layer** — fine because all git/sync/marketplace paths run server-side anyway (§13).
4. **Sync is pull-only, manifest-based.** Agent polls `/sync/:lib` (content-hash manifest), pulls changed files into per-tool directories. No websockets, no push infra in v1; 60s poll is plenty.
5. **Claude Code needs no agent at all** — library doubles as a plugin-marketplace URL. Cheapest, most native integration; the demo that sells the product.
6. **Spec compliance enforced at the boundary** (AI-gen validated + editor validation + git commit hook) → portable by construction.

**Stack:** Next.js (Vercel) web+API · Supabase (Postgres metadata + Storage) · Auth.js w/ Supabase adapter (Google + magic links via email provider) · git backend = Altr-hosted (GitHub org / Gitea) **or** connected GitHub/GitLab/Bitbucket via provider API · sync agent in Go (single static binary, notarized) · **OpenRouter** for AI-authoring + playground · Stripe for billing.

---

## 10. Data model

Supabase Postgres — **metadata only.** Skill *content* lives exclusively in Git; `skills` rows are an index, rebuildable from the repos if ever inconsistent. Auth.js adapter tables (`users`, `accounts`, `sessions`, `verification_tokens`) live in the same database.

```
users(id, email, name)                          -- Auth.js adapter table (+ app columns)
teams(id, name, plan, stripe_customer_id, created_at)
memberships(user_id, team_id, role: admin|editor|viewer)
libraries(id, team_id, slug, git_backend, git_repo_ref, visibility: private|unlisted|public)
skills(id, library_id, name, path, status: draft|in_review|published,
       published_sha, draft_sha, created_by, updated_at)
sync_targets(id, library_id, kind: marketplace|agent|export,
             device_info, last_pulled_at, last_manifest_hash)
approvals(id, skill_id, requested_by, decided_by, state: open|approved|rejected, note, at)
events(id, team_id, actor_id, verb, subject, at)      -- activity feed
model_usage(id, team_id, user_id, kind: generate|improve|playground, tokens, at)  -- quota
share_links(id, skill_id, token, created_by, revoked)  -- v1.1 growth loop
```

**Invariant:** dropping the entire Postgres and rebuilding from the Git backends must lose nothing but derived indexes and analytics. If that's ever untrue, a design bug has crept in.

---

## 11. Interfaces: MCP, CLI, API

### 11.1 MCP server (v0 authoring surface)
Delivered into Claude Code / Claude.ai. Tools:
- `altr_generate_skill(intent, examples?) → skill` — create from plain language.
- `altr_improve_skill(skill_ref, instruction) → skill` — conversational edit.
- `altr_list_skills(library?) → [skill]`
- `altr_publish_skill(skill_ref) → version` — commit + move `published` ref + trigger sync.
- `altr_get_library(slug) → library`

### 11.2 CLI (`altr`)
```
altr login                     # device-token auth
altr init <library>            # create/link a library
altr new "<intent>"            # AI-generate a skill locally
altr improve <skill> "<note>"  # AI edit
altr push / pull               # sync with the library
altr sync                      # write published skills into local tools
altr status                    # drift / version state
```

### 11.3 HTTP endpoints (serve layer)
- `GET /marketplace/:lib` → Claude Code plugin-marketplace JSON + files at `published` ref.
- `GET /sync/:lib` → content-hash manifest for sync agents (ETag-cacheable).
- `GET /sync/:lib/file/:path` → individual published file.
- `GET /s/:token` → public/unlisted read-only skill page ("Add to your library").

All write operations go through authenticated server actions in the Next.js app (never client→DB direct for writes).

---

## 12. Sync protocol & integrations

### 12.1 Protocol
1. Sync agent authenticates with a per-device token.
2. Polls `GET /sync/:lib` every ~60s → receives `{ skillPath: contentHash }` manifest.
3. Diffs against last-seen manifest; downloads only changed files.
4. Writes into each detected tool's skills directory. Records `last_manifest_hash`.
5. Local modifications are detected (hash mismatch not from server) and surfaced as **drift** — never silently overwritten, never auto-pushed (v1).

### 12.2 Per-tool integration matrix
| Tool | Mechanism | Client software | Fidelity |
|---|---|---|---|
| Claude Code | Plugin-marketplace URL | None | Full (native) |
| Cursor | Sync agent → `~/.cursor/skills` | Sync agent | Full |
| OpenAI Codex | Sync agent → `~/.codex/skills` | Sync agent | Full |
| Claude Code (local) | Sync agent → local skills dir | Sync agent | Full |
| Claude.ai | Download zip + upload helper | None | Full (manual step) |
| ChatGPT / GPTs | Export as system-instruction text | None | Degraded (no scripts) |
| AGENTS.md consumers | Composed `AGENTS.md` export | None | Instructions only |

---

## 13. Auth & authorization

- **Auth.js as the sole auth system**, Supabase Postgres adapter, Google OAuth + email magic links.
- **No Supabase Auth** running alongside (one system only).
- **Authorization lives in the server layer.** Because Auth.js doesn't populate Supabase's `auth.uid()`, RLS isn't the guard. Every route handler / server action checks the session's user → `memberships.role` before acting. All sensitive paths (git commits, publish, sync-target config, billing) are server-side, so this is the natural boundary, not a workaround.
- **Roles:** Admin (manage team, billing, roles, approvals), Editor (create/edit/publish or request review), Viewer (read + consume). **Skill Curator** (v2) is a marketplace-level role for reviewing/featuring community submissions, separate from team roles.
- **Device tokens** for CLI and sync agent, scoped to a library + role, revocable.

---

## 14. Security & privacy

- **Libraries private by default**; `unlisted`/`public` are explicit opt-ins.
- **Git backend access** scoped per-user/role; branded remotes gated by device tokens.
- **Skills can contain scripts.** Altr **never executes** skill scripts server-side. The playground runs *instructions through a model*, not scripts. Scripts are render-only in the web UI.
- **Secrets scanning on commit** — block accidental API-key / token commits into shared skills (they're distributed artifacts).
- **Secrets at rest** — user model keys (BYOK) encrypted; never logged.
- **Data export / deletion** — because the repo is the source of truth, full export is inherent; account deletion removes metadata and revokes backend repos.
- **Tenant isolation** — enforced in the server layer on every request (§13).

---

## 15. Non-functional requirements

- **Onboarding:** signup → first synced skill < 10 min (activation target 40%).
- **Sync latency:** published change visible in a connected tool ≤ ~2 min (60s poll + fetch).
- **AI-authoring:** generate a first-draft skill in < 15s p50.
- **Availability:** serve layer (`/marketplace`, `/sync`) is the hard-dependency path — target 99.9%; authoring/dashboard can degrade independently.
- **Scale (year 1):** thousands of libraries, tens of thousands of skills. Git-host-API backend scales without ops; revisit a dedicated git box only past that.
- **Cost control:** managed-model quota hard-capped per seat; BYOK bypasses Altr cost entirely.

---

## 16. Pricing & packaging

| Tier | Price | Includes |
|---|---|---|
| **Free** | $0 | 1 library, 3 members, unlimited public/unlisted skills, **10 private skills**, full versioning, all sync targets, BYOK |
| **Team** | **$12/user/mo** ($10 annual) | Unlimited private skills & libraries, roles, approvals, activity feed, priority sync, **managed-model quota** |
| **Business** *(later)* | ~$25/user/mo | SSO/SAML, audit log, usage analytics, self-hosted sync relay |

**Rationale:** PromptHub anchors the category at $15–20/user/mo; Altr undercuts slightly for the 5–50-seat beachhead. Versioning + sync are free-tier (the hook; the standard makes them expected). The paid surface is **collaboration + control + zero-config AI** (managed model). The sync agent and `altr` CLI are **MIT-licensed** (trust + distribution); the platform is closed.

---

## 17. Go-to-market & growth

0. **Start content NOW (this week, parallel to build):** a **blog + socials** teaching *"how to write awesome skills"* — quick-to-prompt guides, skill teardowns, the standard explained. This is top-of-funnel, SEO surface, and cheap demand validation in one, and it seeds the audience before the product ships. Personal account for socials. (Board: "Start the blog now!")
1. **Pre-build validation (2 weeks, before serious code):** 15 interviews with bridge-team-shaped teams; landing page + waitlist. **Gate: 100 signups or 5 "we'd pay" commitments** before building the sync agent. *(Research inferred the gap from competitor absence, not demonstrated demand — non-optional.)*
2. **Wedge demo (60s):** Maya edits a skill in the browser → Dev's Claude Code picks it up next session → same skill lands in Cursor. The cross-vendor moment is the whole pitch.
3. **Channels:** Claude Code / Cursor communities; "awesome-claude-skills" lists (one-click import of any public skills repo — instant utility + per-repo SEO surface); dev-Twitter/X launch; Product Hunt.
4. **Growth loop:** public skill links render a read-only page with **"Add to your library"** — every shared skill markets the product.

---

## 18. Success metrics

- **Activation:** signup → first skill synced to ≥1 tool < 10 min; target **40%** of signups.
- **North star — bridge teams:** libraries with ≥1 non-technical editor AND ≥1 Git-path user active in the same week. **If this doesn't grow, the thesis is wrong regardless of revenue.**
- **Retention:** weekly synced-skill pulls per team (are skills consumed, not just stored).
- **Authoring adoption:** % of skills created via AI-generate vs. imported/hand-written.
- **Revenue:** 10 paying teams within 60 days of billing launch, else revisit.

---

## 19. Risks & tripwires

| Risk | Signal to watch (monthly) | Response |
|---|---|---|
| **Anthropic ships cross-tool/team skill sync** | Beyond current org-admin deployment | Pivot weight to governance/approvals + non-Anthropic tools; lean into neutrality |
| **Agent Skills moves under AAIF w/ reference sync impl** | Foundation announcement | Become the best-managed *host* of the standard, not a competitor to it |
| **OpenAI/Cursor ship team skill libraries** | Product releases | Double down on cross-vendor neutrality messaging |
| **Low technical moat** (format is just files) | Copycats | Moat = speed, cross-vendor breadth, non-technical UX, and the bridge-team network effect — not tech |
| **Demand unproven** | v0 validation gate misses | Don't build v1; re-scope or stop |

---

## 20. Roadmap & build plan

### Phase v0 — MCP/skill, no web app (~2–3 weeks, validate the loop)
| Step | Deliverable |
|---|---|
| 1 | Git backend wired (GitHub/Gitea API): 1 repo/library, commit-as-user, spec validation on write |
| 2 | AI-authoring engine (Anthropic API): intent → SKILL.md; improve an existing skill |
| 3 | Meta-skill + MCP server ("make me a skill…" → commits + syncs); `altr` CLI |
| 4 | Claude Code marketplace endpoint (library = plugin-marketplace URL) — **first demoable moment** |

→ Ship to 10–15 design partners. **Gate:** does create → version → sync hold before building a dashboard?

### Phase v1 — web app platform (~6 weeks, serve the buyer)
| Week | Deliverable |
|---|---|
| 1 | Next.js + Supabase + Auth.js scaffold (Google + magic link); server-layer authz; data model |
| 2 | AI-generate panel + editor + spec validation + history/restore (prose diff) |
| 3 | Marketplace endpoint in-app + import (repo scan, upload, raw-prompt → AI-scaffold) |
| 4 | Sync agent (macOS: Cursor + Codex + Claude Code local); Claude.ai/ChatGPT export helpers |
| 5 | Teams, roles, invites, draft/publish; playground |
| 6 | Billing (Stripe), landing page, docs; private beta with waitlist teams |

### Phase v1.1+ — see §6 (approvals, analytics, sharing links, AGENTS.md export, cross-platform sync agent).

Risk-ordered: v0's AI-authoring + git + marketplace spine is the novel part; v1 is standard Next.js/Supabase SaaS on a proven core.

---

## 21. Open questions

1. **Demand evidence** — is there direct proof (forum complaints, sales signals) that non-technical teams want Git-free skill versioning + cross-tool sync, and at what price? (v0 gate exists to answer this.)
2. **Anthropic roadmap** — has Claude for Work shipped/roadmapped team skill *sync* since Dec 2025's org-admin deployment, and does it close the wedge?
3. **Standard governance** — will Agent Skills move under AAIF (like MCP/AGENTS.md), and how do Agent Skills and AGENTS.md converge for cross-tool instruction portability?
4. **Landscape completeness** — how do unexamined incumbents (PromptLayer, Langfuse, Latitude, Notion, GPT Store) handle skill/prompt versioning + portability? Is the gap as clean as two verified competitors suggest?
5. **Git backend choice** — GitHub-API (fastest, no ops) vs. self-hosted Gitea (branded remotes, more control) — decide at v1 based on whether `git@altr.run` URLs matter to design partners.

---

## Appendix A — Sources

Verified in research run, 2026-07-03 (22 sources, 105 claims extracted, 24 confirmed via 3-vote adversarial verification):

- **Agent Skills open standard & spec:** agentskills.io, github.com/agentskills/agentskills, github.com/anthropics/skills
- **Anthropic lifecycle intent + org-admin deployment:** anthropic.com engineering post (Dec 18, 2025); support.claude.com org-skills articles; claude.com/blog/organization-skills-and-directory
- **Cross-vendor adoption:** developers.openai.com/codex/skills, cursor.com/docs/context/skills, geminicli.com skills docs
- **Distribution status quo:** github.com/vercel-labs/skills, skills.sh, github.com/netresearch/claude-code-marketplace
- **Pricing anchor:** prompthub.us/pricing ($20/mo monthly, $15 annual; versioning in all tiers)
- **Governance consolidation:** openai.com/index/agentic-ai-foundation, linuxfoundation.org press (Agentic AI Foundation, Dec 9 2025 — AGENTS.md, MCP, goose)
- **Adjacent competitor:** teamprompt.app (DLP + prompt library, chat tools only, no versioning shown)

**One refuted claim (kept for honesty):** "Skills already work seamlessly across all Anthropic surfaces natively" — refuted 1-2. Portability today means *format compatibility*, not *synchronized distribution*. That distinction is the product's core premise.
