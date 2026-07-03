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

### MVP (build in ~6–8 weeks, then charge)
- Library + skill CRUD via web form/editor with spec validation
- Git-backed versioning: history list, prose diff, one-click restore
- Import: GitHub repo scan, folder upload, raw-prompt scaffold
- Sync: Claude Code marketplace endpoint + macOS sync agent (Cursor, Codex, Claude Code local) + zip/text export
- Draft/publish, roles (Admin/Editor/Viewer), email invites, Google SSO
- Skill playground (test against Claude API)
- Free/Team billing (Stripe)

### V1.1 (fast follows)
- Approval workflow; activity feed; pull-count analytics
- Windows/Linux sync agent; `altr` CLI for CI
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
┌────────────── Web app (Next.js) ──────────────┐
│  Editor · History/Diff · Playground · Admin   │
└───────────────┬───────────────────────────────┘
                │ REST/tRPC
┌───────────────▼───────────────────────────────┐
│  API server (Node/TS)                         │
│  · Auth (Google SSO, magic links)             │
│  · Skill service — validate, commit, publish  │
│  · Postgres: users, teams, libraries, roles,  │
│    billing, sync-state (metadata only)        │
└──────┬──────────────────┬─────────────────────┘
       │                  │
┌──────▼───────┐   ┌──────▼──────────────────────┐
│ Git service  │   │ Serve layer                 │
│ bare repos,  │   │ · /marketplace/:lib →       │
│ 1 per library│   │   Claude Code plugin        │
│ (fs + git,   │   │   marketplace JSON + files  │
│ SSH+HTTPS)   │   │ · /sync/:lib → manifest for │
└──────────────┘   │   sync agents (ETag/hash)   │
                   └─────────────┬───────────────┘
                                 │ HTTPS pull
                   ┌─────────────▼───────────────┐
                   │ Sync agent (Go, menu bar)   │
                   │ tool detection → writes to  │
                   │ ~/.cursor/skills, ~/.codex/…│
                   └─────────────────────────────┘
```

**Load-bearing decisions**

1. **The Git repo is the source of truth; Postgres holds only metadata.** This keeps us honest (everything exportable, no lock-in — a trust requirement for the dev persona) and makes the marketplace endpoint trivial (serve files from the repo at the published ref).
2. **Web saves are commits** authored as the user, via server-side `git` on bare repos (plain `git` CLI on the server; no libgit2 complexity until scale demands it). Publish = move the `published` ref.
3. **Sync is pull-only, manifest-based**: agent polls `/sync/:lib` (content-hash manifest), downloads changed files, writes into per-tool directories. No websockets, no push infra in v1; 60s poll is fine for this use case.
4. **Claude Code needs no agent at all** — a library doubles as a plugin-marketplace URL. This is the cheapest, most native integration and the demo that sells the product.
5. **Spec compliance enforced at the boundary** (web form validation + Git push hook), so every stored skill is portable by construction.

**Stack:** Next.js + tRPC + Postgres (managed, e.g. Neon/RDS) + S3 for large assets + plain git on a persistent volume; sync agent in Go (single static binary, easy notarization). Anthropic API for the playground. Stripe for billing. All boring on purpose.

**Security:** libraries private by default; repo access via per-user SSH keys/HTTPS tokens scoped to role; sync agent auths with a device token; skills can contain scripts → render-only in web (never execute server-side except the playground, which runs instructions through the model, not scripts); secrets scanning on commit (skills are shared artifacts — block accidental API-key commits).

---

## 7. Data model (Postgres — metadata only)

```
users(id, email, name, auth_provider)
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

## 11. Build plan (solo/duo, ~8 weeks to paid MVP)

| Week | Deliverable |
|---|---|
| 1 | Repo/infra scaffold; Git service (bare repos, commit-as-user, push-hook validation); data model |
| 2 | Skill editor + spec validation + history/restore |
| 3 | Claude Code marketplace endpoint (E2E: edit in web → appears in Claude Code) — **first demoable moment** |
| 4 | Import (repo scan, upload, prompt scaffold); prose diff view |
| 5 | Sync agent v0 (macOS: Cursor + Codex + Claude Code local) |
| 6 | Teams, roles, invites, draft/publish |
| 7 | Playground; Claude.ai/ChatGPT export helpers; polish |
| 8 | Billing, landing page, docs; private beta with 10 waitlist teams |

Risk-ordered: the Git+marketplace spine (weeks 1–3) is the novel part; everything after is standard SaaS.

---

## Appendix A — Key sources (verified in research run, 2026-07-03)

- Agent Skills open standard & spec: agentskills.io, github.com/agentskills/agentskills, anthropics/skills
- Anthropic lifecycle intent + org-admin deployment: anthropic.com engineering post (Dec 18, 2025); support.claude.com org-skills articles
- Cross-vendor adoption: developers.openai.com/codex/skills, cursor.com/docs/context/skills, geminicli.com skills docs
- Distribution status quo: vercel-labs/skills CLI, skills.sh, netresearch/claude-code-marketplace
- Pricing anchor: prompthub.us/pricing ($20/mo monthly, $15/mo annual, versioning in all tiers)
- Governance consolidation: Agentic AI Foundation (Linux Foundation, Dec 9 2025 — AGENTS.md, MCP, goose)
- Adjacent competitor: teamprompt.app (DLP + prompt library, chat tools only, no versioning shown)
