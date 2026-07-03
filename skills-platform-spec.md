# Altr — Product Specification v1.0

> Name: **Altr** (altr.run) — a skill *alters* how your agent behaves; `.run` because agents run skills. "GitHub for your team's AI skills, without the Git."
>
> Date: 2026-07-03 · Author: Mukul Chugh · Status: Draft for validation

---

## 1. One-liner & thesis

**Altr is a shared library where a team creates, versions, and syncs AI agent skills across every tool they use — Claude Code, Claude.ai, Cursor, OpenAI Codex, ChatGPT — with zero Git knowledge required.**

Thesis (from verified research, July 2026):

1. The **Agent Skills open standard** (SKILL.md folders, agentskills.io) is adopted by 42+ tools across competing vendors. The format war is over. We build ON the standard, never a new format.
2. Distribution today is Git/CLI-only (`npx skills add`, plugin marketplaces). **No product offers Git-free versioning + non-technical UX + cross-vendor sync.**
3. Vendors will sync skills within their own ecosystems (Anthropic already ships org-admin deployment). **No vendor will sync between ecosystems.** Cross-vendor neutrality is the durable wedge.
4. Versioning is table-stakes (PromptHub includes it free). We monetize private workspaces, permissions, approvals, and sync — at the market-anchored $10–15/user/mo.

**Non-goals:** prompt observability/evals (Langfuse's market), LLM DLP/compliance (TeamPrompt's market), a public skills marketplace (vendors' market), building agents.

---

## 2. Personas

| Persona | Who | Pain | What they need |
|---|---|---|---|
| **Maya, Ops lead** (primary buyer) | Non-technical, lives in Claude.ai/ChatGPT | Team's best prompts/SOPs live in a Google Doc; everyone pastes stale copies | Create & edit skills in a form; one library; know which version is current |
| **Dev, senior engineer** (primary adopter) | Claude Code + Cursor daily | Wrote great skills; sharing = "clone this repo", non-devs never do | Keep Git workflow; teammates' improvements flow back; no babysitting |
| **Priya, team lead** (champion) | Semi-technical, manages both | No single source of truth; no review before a skill goes team-wide | Approvals, roles, usage visibility |

Target customer: teams of 5–50 where engineers use agentic coding tools AND non-engineers use chat tools. Beachhead: AI-forward startups and agencies.

---

## 3. Core concepts

- **Skill** — a spec-compliant Agent Skills folder: `SKILL.md` (YAML frontmatter: `name`, `description`) + markdown instructions + optional `scripts/`, `references/`, `assets/`. Altr never stores skills in a proprietary shape; the folder IS the record.
- **Library** — a team workspace holding skills. Backed 1:1 by a real Git repository (invisible to non-technical users, cloneable by engineers).
- **Version** — a Git commit, surfaced as a human list: "v4 · Maya · yesterday · 'added refund edge case'" with one-click restore/diff.
- **Target** — a destination a skill syncs to: Claude Code (marketplace), local disk (Cursor/Codex via sync agent), Claude.ai (upload helper), export bundle.
- **Channel** — `draft` → `published`. Only published versions sync. Optional approval gate between them.

---

## 4. User flows

### 4.1 Onboarding (must be < 5 minutes to first synced skill)
1. Sign up (Google SSO) → create Library ("Acme Team") → invite via email link.
2. Import existing skills: paste a GitHub repo URL (we scan for SKILL.md folders), upload a folder/zip, or paste raw prompt text (we scaffold a valid skill from it).
3. Connect first target: for Claude Code we show the one-liner `claude plugin marketplace add acme.altr.run`; for Cursor/Codex, install the sync agent (`brew install altr` or download).
4. First skill appears in the tool. Confetti.

### 4.2 Maya creates a skill (non-technical path)
1. "New Skill" → form: Name, "When should the AI use this?" (→ description), Instructions (rich markdown editor with live preview).
2. Optional: attach reference files (drag-drop → `references/`).
3. "Test it" — a playground pane runs the skill against the Claude API on a sample task so she sees it work before publishing.
4. Save = commit. Publish (or "Request review" if approvals are on) → syncs to all connected targets.
5. She never sees YAML, Git, or a terminal. The editor enforces spec constraints (name ≤64 chars lowercase-hyphen, description ≤1024 chars) as friendly validation, not errors after the fact.

### 4.3 Dev edits from the terminal (technical path)
1. `git clone git@altr.run:acme/skills.git` — the library is a plain repo.
2. Edits SKILL.md in his editor, commits, pushes. Push hook validates against the spec (`skills-ref validate` semantics) and rejects broken frontmatter with a clear message.
3. His push appears in the web UI as a new version; Maya sees "Dev updated *code-review-checklist*" and can read the diff rendered as prose, not patch syntax.
4. Conflicts: last-write-wins per skill with full history (restore anything); true Git merge is available to Git users. No merge UI for non-technical users in v1.

### 4.4 Skill consumption (the sync fan-out)
- **Claude Code**: each library is served as a plugin marketplace endpoint. Team adds it once; updates flow on Claude Code's normal refresh. Zero client software.
- **Cursor / Codex / other local-disk tools**: the **sync agent** (small daemon + menu bar item) pulls published skills into each tool's skills directory (`~/.cursor/skills`, `~/.codex/skills`, etc. — reuse vercel-labs `skills` CLI's 70+ tool detection map). Pull-only in v1; local edits are flagged "drifted," not pushed.
- **Claude.ai**: no API for org skill upload as of research date → "Download for Claude.ai" zip + step-by-step upload helper; org-admin API integration the moment Anthropic exposes one.
- **ChatGPT / GPTs**: export skill as system-instruction text block with copy button. (Format degrades gracefully: instructions carry over; scripts don't.)
- **agents.md**: per-repo export that emits an AGENTS.md composed from selected skills, for tools that consume that standard instead.

### 4.5 Governance (paid)
- Roles: Admin / Editor / Viewer.
- Optional approval workflow: Editors submit, Admins approve → publish.
- Activity feed + per-skill usage signal (v1: sync-pull counts per target; later: opt-in usage telemetry from the sync agent).

---

## 5. Feature scope

**AI-authoring is the core interaction, not a garnish.** Nobody in the non-technical audience hand-writes YAML + markdown. The primary way skills come into being is: *describe intent in plain language → Altr generates a spec-compliant skill; select an existing skill → "improve / tighten / add an edge case."* This is the hook that makes the product usable by non-writers, and it's what the models are for.

### Phase v0 — no web app (validate the loop cheaply)
Ship AI-authoring + sync **inside the tools people already use**, so there's near-zero frontend to build:
- **Meta-skill + MCP server** — in Claude Code or Claude.ai the user says *"make me a skill that does X"* → Altr generates the skill, commits it to their git-backed library, syncs it out. "The skill that writes skills" (Altr dogfoods itself).
- Git-backed versioning behind the scenes; management via `altr` CLI + the git host's own web view.
- Claude Code marketplace endpoint (library = plugin-marketplace URL).
- **Goal:** prove create → version → sync with engineers/early adopters before building any dashboard.

### Phase v1 — the web app platform (serve the non-technical buyer)
The dashboard is what a chat box can't do — this is where Maya lives:
- **AI-generate panel** (same authoring engine as v0) + rich markdown editor with live preview and spec validation
- Git-backed versioning: history list, prose diff, one-click restore
- Import: GitHub repo scan, folder upload, raw-prompt → AI-scaffold
- Sync: marketplace endpoint + macOS sync agent (Cursor, Codex, Claude Code local) + Claude.ai/ChatGPT export
- Library/skill management, teams, roles (Admin/Editor/Viewer), email invites, auth
- Skill playground (test against a model)
- Free/Team billing (Stripe)

### V1.1 (fast follows)
- Approval workflow; activity feed; pull-count analytics
- Windows/Linux sync agent; `altr` CLI in CI
- Public/unlisted skill sharing links (growth loop)
- AGENTS.md export

### Later / explicitly deferred
- Two-way sync from local edits (drift → PR-like proposal)
- Skill analytics from agent telemetry; A/B versions
- Enterprise: SAML, SCIM, audit log, self-hosting
- Community/public directory (only if vendors leave it open)
- **Never:** proprietary skill format, agent runtime, prompt-eval platform

---

## 6. Architecture

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

1. **The Git repo is the source of truth; Supabase Postgres holds only metadata.** Everything is exportable, no lock-in (a trust requirement for the dev persona), and the marketplace endpoint is trivial (serve files at the published ref).
2. **Git does not run on Vercel.** Next.js on Vercel is serverless — no persistent filesystem — so the git engine lives behind an API the app calls. Start with a **git host's API (GitHub/Gitea) as the backend** (versioning, diffs, history, a cloneable remote — zero git-ops). Move to a **small self-hosted Gitea box** only if branded `git clone git@altr.run:…` URLs become a launch requirement.
3. **Auth = Auth.js, sole system** (no Supabase Auth alongside it), using the **Supabase Postgres adapter** — auth tables live in the same Supabase, one database. Google OAuth + email magic links (email provider e.g. Resend). Consequence, accepted: no Supabase RLS `auth.uid()`, so **authorization is enforced in the server layer** (route handlers / server actions with the service-role key + role checks) — fine because all git/sync/marketplace paths run server-side anyway.
4. **Sync is pull-only, manifest-based**: agent polls `/sync/:lib` (content-hash manifest), pulls changed files into per-tool directories. No websockets, no push infra in v1; 60s poll is plenty.
5. **Claude Code needs no agent at all** — a library doubles as a plugin-marketplace URL. Cheapest, most native integration and the demo that sells the product.
6. **Spec compliance enforced at the boundary** (AI-gen output validated + editor validation + git commit hook), so every stored skill is portable by construction.

**Stack:** **Next.js (Vercel)** for web app + API (server actions / route handlers) · **Supabase** (Postgres metadata + Storage for assets) · **Auth.js** with the Supabase Postgres adapter (Google OAuth + magic links via an email provider) · **git backend** = GitHub/Gitea API (→ small Gitea box if vanity remotes needed) · **sync agent** in Go (single static binary, easy notarization) · **Anthropic API** for AI-authoring + playground · **Stripe** for billing. Boring on purpose.

**Models / BYOK:** BYOK is the universal default (customers already have keys); paid tiers bundle a **capped managed-model quota** so non-technical users get zero-config AI-authoring + playground without ever touching an API key. Not sold as a standalone model SKU — it's friction removal priced into the seat.

**Security:** libraries private by default; git backend access scoped per-user/role; sync agent auths with a device token; skills can contain scripts → render-only in web (never execute server-side; the playground runs instructions through the model, not scripts); secrets scanning on commit (block accidental API-key commits into shared skills).

---

## 7. Data model (Supabase Postgres — metadata only)

> Plus the Auth.js adapter tables (`users`, `accounts`, `sessions`, `verification_tokens`) in the same database. The `users` table below is the Auth.js users table, extended with app columns.

```
users(id, email, name)                          -- Auth.js adapter table
teams(id, name, plan, stripe_customer_id)
memberships(user_id, team_id, role: admin|editor|viewer)
libraries(id, team_id, slug, git_repo_path, visibility)
skills(id, library_id, name, path, published_ref, draft_ref,
       status: draft|in_review|published, created_by)
sync_targets(id, library_id, kind: marketplace|agent|export,
             last_pulled_at, device_info)
approvals(id, skill_id, requested_by, decided_by, state, note)
events(id, team_id, actor, verb, subject, at)   -- activity feed
```

Skill *content* lives only in Git. `skills` rows are an index over the repo, rebuilt from it if ever inconsistent.

---

## 8. Pricing

| Tier | Price | Includes |
|---|---|---|
| **Free** | $0 | 1 library, 3 members, unlimited public/unlisted skills, 10 private skills, full versioning, all sync targets |
| **Team** | **$12/user/mo** ($10 annual) | Unlimited private skills & libraries, roles, approvals, activity feed, priority sync |
| **Business** (later) | ~$25/user/mo | SSO/SAML, audit log, usage analytics, self-hosted sync relay |

Rationale: PromptHub anchors the category at $15–20/user/mo; we undercut slightly to reduce friction for the 5–50-seat beachhead. Versioning and sync are free-tier (they're the hook and the standard makes them expected); collaboration and control are the paid surface. The sync agent and any CLI are MIT-licensed (trust + distribution); the platform is closed.

---

## 9. Go-to-market

1. **Pre-build validation (2 weeks, before serious code):** 15 interviews with teams matching the persona split; a landing page with the one-liner + waitlist; target 100 signups or 5 "we'd pay" commitments before the sync agent is written. *The research inferred the gap from competitor absence, not demonstrated demand — this step is not optional.*
2. **Wedge demo:** 60-second video — Maya edits a skill in the browser, Dev's Claude Code picks it up on next session, same skill lands in Cursor. That cross-vendor moment is the whole pitch.
3. **Channels:** Claude Code / Cursor communities, "awesome-claude-skills" lists (offer one-click import of any public skills repo — instant utility, SEO surface per imported repo), X/dev-Twitter launch, Product Hunt.
4. **Growth loop:** public skill links render a read-only skill page with "Add to your library" — every shared skill markets the product.

**Tripwires (check monthly):**
- Anthropic ships cross-tool or team skill **sync** beyond org-admin deployment → pivot weight toward governance/approvals + non-Anthropic tools.
- Agent Skills moves under AAIF with a reference sync implementation → become the best-managed host of it rather than compete with it.
- OpenAI/Cursor ship team skill libraries → double down on cross-vendor neutrality messaging.

---

## 10. Success metrics

- **Activation:** signup → first skill synced to ≥1 tool < 10 min; target 40% of signups.
- **The metric that matters:** libraries with ≥1 non-technical editor AND ≥1 Git-path user active in the same week ("bridge teams"). If this doesn't grow, the thesis is wrong regardless of revenue.
- **Retention:** weekly synced-skill pulls per team (are skills actually consumed, not just stored).
- **Revenue:** 10 paying teams within 60 days of billing launch, else revisit.

---

## 11. Build plan (solo/duo)

### Phase v0 — MCP/skill, no web app (~2–3 weeks, validate the loop)
| Step | Deliverable |
|---|---|
| 1 | Git backend wired (GitHub/Gitea API): 1 repo/library, commit-as-user, spec validation on write |
| 2 | AI-authoring engine (Anthropic API): plain-language intent → spec-compliant SKILL.md; improve/enhance an existing skill |
| 3 | Meta-skill + MCP server ("make me a skill…" in Claude Code/Claude.ai → commits + syncs); `altr` CLI |
| 4 | Claude Code marketplace endpoint (library = plugin-marketplace URL) — **first demoable moment** |

→ Ship to 10–15 design partners. Gate: does the create → version → sync loop hold before building a dashboard?

### Phase v1 — web app platform (~6 weeks, serve the buyer)
| Week | Deliverable |
|---|---|
| 1 | Next.js + Supabase + Auth.js scaffold (Google + magic link); server-layer authz; data model |
| 2 | AI-generate panel + editor + spec validation + history/restore (prose diff) |
| 3 | Marketplace endpoint in-app + import (repo scan, upload, raw-prompt → AI-scaffold) |
| 4 | Sync agent (macOS: Cursor + Codex + Claude Code local); Claude.ai/ChatGPT export helpers |
| 5 | Teams, roles, invites, draft/publish; playground |
| 6 | Billing (Stripe), landing page, docs; private beta with waitlist teams |

Risk-ordered: v0's AI-authoring + git + marketplace spine is the novel part; the v1 web app is standard Next.js/Supabase SaaS on top of a proven core.

---

## Appendix A — Key sources (verified in research run, 2026-07-03)

- Agent Skills open standard & spec: agentskills.io, github.com/agentskills/agentskills, anthropics/skills
- Anthropic lifecycle intent + org-admin deployment: anthropic.com engineering post (Dec 18, 2025); support.claude.com org-skills articles
- Cross-vendor adoption: developers.openai.com/codex/skills, cursor.com/docs/context/skills, geminicli.com skills docs
- Distribution status quo: vercel-labs/skills CLI, skills.sh, netresearch/claude-code-marketplace
- Pricing anchor: prompthub.us/pricing ($20/mo monthly, $15/mo annual, versioning in all tiers)
- Governance consolidation: Agentic AI Foundation (Linux Foundation, Dec 9 2025 — AGENTS.md, MCP, goose)
- Adjacent competitor: teamprompt.app (DLP + prompt library, chat tools only, no versioning shown)
