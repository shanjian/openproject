# Upstream Sync Plan

**Goal:** keep absorbing upstream OpenProject **security fixes, bug fixes, and performance
improvements** without destabilising the fork's own logic.
**Explicit non-goal:** acquiring upstream's new features.

**Measured:** 2026-08-11, against `upstream` = `https://github.com/opf/openproject.git`.
All numbers below were derived from real trial merges (`git merge-tree`), not estimates.
See [Appendix A](#appendix-a-how-to-recompute-these-numbers) to re-derive them — they drift
as upstream moves.

---

## 1. Where the fork stands

| Fact | Value |
|---|---|
| Fork point | `0774914fa48` — "Update publiccode.yml", 2026-02-26, on upstream **`dev`** (not a release tag) |
| Fork trunk | `epic` (per `CLAUDE.md`, this is the default/main branch) |
| Fork's own commits | 308 |
| Fork's footprint | 1,610 modified upstream files, 518 added, 50 deleted |
| Upstream commits since fork point | ~7,700+ |
| Latest upstream release | **v17.7.1** |
| Merge base | single and clean — no criss-cross, merges are well-defined |
| `origin/dev` | a **pure upstream mirror** (strict ancestor of `upstream/dev`), stale since 2026-02-25 — a useful asset, keep it clean |
| Schema file | `db/structure.sql` is **git-ignored** → never conflicts, but must be regenerated locally each hop |
| Test suite | ~3,188 spec files |

### The constraint that drives everything

**The 17.1 line the fork is based on is end-of-life upstream.** `upstream/release/17.1`
last received a commit on 2026-03-31. Upstream backports security and bug fixes only to
the **current** release line (now `release/17.7` / `stable/17`) and to `dev`.

Consequence: there is no "security-only patch stream" available for where the fork sits
today. After v17.1.4, the 17.1 well is permanently dry.

---

## 2. Strategy decision — and the "no new features" tension

The stated preference (fixes yes, features no) cannot be satisfied literally by any git
operation. Upstream does not separate fix commits from feature commits into different
streams, and the fixes you want are written against code that has moved 7,700 commits.
Two honest options:

**Option A — Cherry-pick individual fixes forever.** Preserves feature-purity. But: no
cumulative progress, per-fix porting cost rises without bound as drift grows, fixes
touching any of your 1,610 modified files often will not apply at all, and you must
manually track every upstream advisory yourself. This lane degrades to unusable.

**Option B — Stepwise catch-up merges (recommended).** Get current, then stay current with
small regular merges. You *do* receive upstream's new features as code.

**The resolution:** merging feature *code* is not the same as exposing features to *users*.
OpenProject gates functionality at three layers you control after merging:

- `OpenProject::FeatureDecisions` (`lib_static/open_project/feature_decisions.rb`) — flags,
  default-off
- per-project module enable/disable
- admin settings

So the workable answer to "we don't want new features" is: **merge the code, leave the
features off.** That keeps you eligible for cheap future security fixes — which is the
actual goal — without changing what your users see.

**Recommended: Option B, with Option A retained only as an emergency lane** (see §9) for a
critical advisory that lands mid-catch-up.

---

## 3. The real size of the job

Raw conflict counts are dominated by noise. Decomposed:

| Target | Raw conflicts | Crowdin locale | Docs+spec | Jira dupe | **Real app code** |
|---|---|---|---|---|---|
| v17.1.4 | 5 | 0 | 0 | 0 | **3** |
| v17.2.4 | 369 | 222 | 49 | 23 | **63** |
| v17.3.4 | 746 | ~460 | 101 | 22 | **148** |
| v17.4.1 | 836 | ~461 | 140 | 42 | **179** |
| v17.5.1 | 876 | ~461 | 138 | 50 | **208** |
| v17.6.0 | 911 | ~464 | 140 | 51 | **233** |
| v17.7.1 | 1,033 | 514 | 171 | 51 | **268** |

Counts are *cumulative from `epic` as it stands today*, so the marginal cost of each hop
performed in sequence is lower than the difference between rows (earlier resolutions carry
forward, especially with `rerere`).

**Marginal real-code cost per hop:** 17.2 ≈ +60, 17.3 ≈ +85, 17.4 ≈ +31, 17.5 ≈ +29,
17.6 ≈ +25, 17.7 ≈ +35.

**Two conclusions:**
1. Full catch-up is ~**268 files of genuine hand-merging**, not a thousand. Over half the
   raw count is Crowdin translation YAML resolvable by a mechanical rule (§6.1).
2. **The pain is front-loaded in 17.2 and 17.3.** After 17.3 each hop is a routine ~30
   files. Stopping at 17.2 leaves the worst hop still ahead — plan to reach 17.3 at minimum.

**Cost of delay:** ~25–35 additional real-code conflicts per upstream release, at roughly
one release per month.

---

## 4. Prerequisites — do these once, before any merge

| # | Action | Why | Risk |
|---|---|---|---|
| 0.1 | `git fetch upstream --tags --prune` | Numbers above go stale; confirm the current latest tag | None |
| 0.2 | `git config rerere.enabled true` and `git config rerere.autoupdate true` | Records conflict resolutions and replays them on later hops. Without this you re-resolve the same collisions every hop. **Highest-leverage single setting in this plan.** | None |
| 0.3 | Confirm CI is green on `epic` before starting | Establishes the baseline. Without it you cannot tell merge-induced breakage from pre-existing breakage. | None |
| 0.4 | Capture a baseline spec run on `epic` (full suite, record failures) | Same reason. Pre-existing failures must be known or every hop looks like a regression. | None |
| 0.5 | Tag the starting point: `git tag pre-sync-baseline epic` | Cheap, unambiguous rollback anchor | None |
| 0.6 | Decide the Departments question (§5, Step 4 note) | Determines whether work continues on the fork's port | None (decision only) |
| 0.7 | Ensure a clean working tree; do this work on a dedicated branch, never directly on `epic` | | None |

**Note:** the current checked-out branch is `fix/gitlab-branch-convention-untruncated-type`.
Start from `epic`.

---

## 5. The hops

General shape for every hop N:

```bash
git fetch upstream --tags
git checkout -b sync/<version> epic          # or onto the previous sync branch
git merge <tag>                              # e.g. v17.2.4 — merge the TAG, not the branch
# resolve per §6
git commit
# run §7 verification
# open a PR into epic, merge with a merge commit (not squash — preserves ancestry)
```

**Always merge the last patch release of a line** (`v17.2.4`, not `v17.2.0`) — you get the
line's bug fixes for free in the same hop.

**Ancestry matters:** use real merges throughout. Squashing or rebasing destroys the
ancestry that makes each *subsequent* hop cheap, and would force git to re-derive every
prior conflict. This is the single most damaging mistake available in this plan.

---

### Step 1 — `v17.1.4` (close out the 17.1 line)

- **Conflicts:** 3 real
  - `docker/prod/Dockerfile` (content)
  - `lib/open_project/version.rb` (content — always conflicts, always take upstream's
    numbers; see §6.4)
  - a **rename/rename false positive**: git claims `app/helpers/project_helper.rb` was
    renamed to two unrelated migrations. It was not — this is rename detection misfiring.
    Resolution: keep `app/helpers/project_helper.rb`, and keep **both** migrations
    (`20260203171223_remove_default_from_work_packages_subject.rb` from the fork,
    `20260313120000_strip_control_characters_from_custom_field_names.rb` from upstream).
- **Risk: LOW.** Half a day including verification.
- **Value:** harvests everything upstream will ever ship for 17.1. Do this even if the rest
  of the plan is deferred.

---

### Step 2 — `v17.2.4`

- **Conflicts:** 369 raw → **63 real app code** (backlogs 20, `frontend/src` 10, meeting 7,
  `app/models` 5, components 4, controllers 3, gitlab_integration 2, forms 2, docker 2,
  misc 3), plus 222 Crowdin (mechanical), 26 specs, 23 docs, 23 Jira, 4 CI, 4 lockfiles,
  9 upstream migrations.
- **Risk: MEDIUM–HIGH.** The first substantial hop and the first exercise of every
  resolution policy.
  - *Backlogs collisions (20 files)* — this is the fork's most-customised module
    (`Agile::Sprint` refactor, Release = Version + kind) meeting upstream's active
    Primer migration of the same components. **Highest regression risk in the entire plan.**
    Mitigation: resolve backlogs last, in its own commit, with the backlogs spec suite run
    in isolation before moving on.
  - *Jira importer add/add (23 files)* — see §6.2.
  - *9 new upstream migrations* — see §6.5.
- **Effort:** 3–5 focused days including verification.

---

### Step 3 — `v17.3.4`

- **Conflicts:** ~+85 real app code beyond Step 2. **The largest single hop.**
- **Risk: HIGH.** Same failure modes as Step 2 at greater volume.
- **Do not stop before completing this step.** 17.2 and 17.3 together are the hump; the
  remaining hops are routine only once it is behind you.

---

### Step 4 — `v17.4.1`

- **Conflicts:** ~+31 real app code. 4 upstream migrations.
- **Risk: MEDIUM**, but with one structural decision attached.
- **⚠ Departments collision.** Upstream shipped Departments in 17.4.x (36 files) and has
  grown it to 172 files by 17.7.1, at `app/components/admin/departments/…`. The fork's own
  Departments port sits at `app/components/departments/…` — **different paths**. Only 5
  paths overlap, so this does *not* produce add/add conflicts; instead this hop silently
  lands **upstream's Departments alongside the fork's**, leaving two parallel
  implementations with the fork's 42-file version as permanent dead weight tracking a
  feature upstream is actively expanding.
  - **Decide at prerequisite 0.6, before Step 4:** either (a) retire the fork's port and
    adopt upstream's — strongly preferred, and it means *stopping further investment in the
    port now* — or (b) keep both and accept the maintenance cost forever.
  - Under (a), disable upstream's Departments via module/feature gating if you don't want
    it user-visible. That is the §2 principle applied concretely.

---

### Step 5 — `v17.5.1`

- **Conflicts:** ~+29 real app code. **16 upstream migrations** — the largest migration
  batch of the sequence.
- **Risk: MEDIUM.** Migration volume is the notable factor; see §6.5.

---

### Step 6 — `v17.6.0`

- **Conflicts:** ~+25 real app code. 3 migrations.
- **Risk: LOW–MEDIUM.** Routine by this point.

---

### Step 7 — `v17.7.1` (current)

- **Conflicts:** ~+35 real app code. **21 upstream migrations.**
- **Risk: MEDIUM.**
- On completion the fork is current and eligible for cheap ongoing security fixes. Proceed
  to §8.

---

## 6. Standing resolution policies

Apply these uniformly. They are what turns 1,033 conflicts into ~268 decisions.

### 6.1 Crowdin translation YAML — take upstream wholesale

`config/locales/crowdin/*.yml` (514 of the conflicts at 17.7.1) are machine-managed
translation files. Never hand-merge them.

```bash
git diff --name-only --diff-filter=U | grep 'config/locales/crowdin/' \
  | xargs -r git checkout --theirs --
git diff --name-only --diff-filter=U | grep 'config/locales/crowdin/' | xargs -r git add
```

**Hand-merge only the source files** — `en.yml` / `js-en.yml` (11 files at 17.7.1: root
`config/locales/en.yml`, `js-en.yml`, and the backlogs / boards / costs / documents /
gitlab_integration / grids / meeting module equivalents). These hold the fork's own
translation keys and **must** retain them — union of both sides, never take-one-side.

**Risk: LOW**, with one caveat — dropping a fork key from `en.yml` produces a missing
translation visible in the UI rather than a test failure. `i18n-tasks` (already in CI)
catches this; run it per hop.

### 6.2 Jira importer — adopt upstream's implementation

The fork and upstream both carry a Jira importer at the same paths with independent
lineage; upstream shipped it in v17.2.0 and the two have diverged (17 files, +289/−42).
This produces 23 add/add conflicts at 17.2, rising to 51 by 17.7 — git cannot auto-resolve
any of them.

**Policy:** take upstream's implementation as the base, then re-apply the fork's
intentional deltas on top. Do not attempt a line-by-line merge of two independent
implementations.

**Risk: MEDIUM.** Requires knowing which fork deltas were deliberate. Review
`git log 0774914fa48..epic -- app/services/import app/workers/import app/components/admin/import`
first and write the delta list down *before* resolving.

### 6.3 Don't repeat the duplicate-lineage mistake

Both the Jira importer and Departments became expensive because an upstream feature was
brought into the fork by hand-copying rather than by merging. **Rule going forward: acquire
upstream features by merging the release that contains them, never by porting by hand.**
Hand-porting guarantees a future add/add conflict or a silent duplicate implementation.

### 6.4 `lib/open_project/version.rb`

Conflicts at every hop. Always take upstream's version numbers — the fork's edition marker,
if any, goes elsewhere. **Risk: LOW.**

### 6.5 Migrations

`db/structure.sql` is git-ignored, so it never conflicts — but it must be regenerated after
each hop (`bundle exec rails db:migrate`) and the result sanity-checked.

The fork has added 23 migrations since the fork point; upstream adds 1/9/7/4/16/3/21 across
the seven hops. Rails runs migrations in timestamp order, and the two sets interleave.

**Risk: MEDIUM — the most under-appreciated risk in this plan.** Interleaving is usually
harmless but breaks when a fork migration assumes a schema state that an upstream migration
with an earlier timestamp now changes first (or vice versa).

**Mitigation, per hop:** run `bundle exec rails db:migrate` from an *empty* database and
from a *production-like restored dump*. The empty-DB path catches ordering inversions; the
restored-dump path catches migrations that are non-idempotent against real data. Both must
pass. Never test only the incremental path from your dev database.

### 6.6 Never auto-resolve

Do not use `-X ours` / `-X theirs` as a blanket merge strategy. They silently discard one
side across the whole merge — exactly the regression class this plan exists to prevent.
The `--theirs` usage in §6.1 is per-file and deliberate.

### 6.7 Lockfiles

`Gemfile.lock` and `frontend/package-lock.json` conflict every hop. Resolve by taking
upstream's `Gemfile` / `package.json`, re-applying fork-specific dependency lines, then
**regenerating** the lockfile (`bundle install`, `npm install`) — never hand-merge lockfile
content. **Risk: LOW**, but hand-merged lockfiles produce irreproducible builds.

---

## 7. Verification protocol — run per hop, no exceptions

A hop is not done until all of these pass. Compare against the §4 baseline, not against
zero.

| Check | Command | Catches |
|---|---|---|
| Migrations, empty DB | `bundle exec rails db:drop db:create db:migrate` | ordering inversions |
| Migrations, real data | restore production-like dump, then `db:migrate` | non-idempotent migrations |
| Ruby lint | `bundle exec rubocop` | resolution syntax damage |
| ERB lint | `erb_lint` on changed templates | broken template merges |
| JS/TS lint | `cd frontend && npx eslint src/` | |
| i18n | `i18n-tasks` (CI workflow exists) | translation keys dropped in `en.yml` merges |
| Full spec suite | `bundle exec rake parallel:spec` | regressions |
| Targeted: backlogs | `bundle exec rspec modules/backlogs/spec` | the highest-risk module |
| Targeted: fork features | meeting, boards, gitlab_integration, costs, budgets specs | fork logic |
| Security scanners | `brakeman-scan-core`, `codeql-scan-core` (CI workflows exist) | |
| Manual smoke | sprint board, boards, meetings, GitLab integration, Epic field, Release/Version behaviour | what specs miss |

**Manual smoke matters most for the fork's own features** — the areas the fork rewrote are
exactly where upstream's changes are most likely to have broken an assumption the specs
don't encode.

---

## 8. Steady state after catch-up

Once current, the cost model inverts — staying current is cheap, falling behind is not.

- **Cadence:** merge each new upstream patch release within ~2 weeks of publication; each
  minor release within ~1 month. At that cadence a hop is a handful of files.
- **Keep `origin/dev` a pure upstream mirror.** Fast-forward it from `upstream/dev`
  regularly and never commit fork work to it. It is the clean reference for every future
  measurement.
- **Watch:** `upstream/stable/17` and the current `upstream/release/17.x` — where security
  fixes land.
- **Dependency lane, independent of all merging:** `dependabot.yml` and the
  `dependency-review` / `brakeman` / `codeql` workflows are already configured. Gem and npm
  CVEs (rails, rack, nokogiri, puma) can be patched **without touching upstream application
  code at all**. This is the cheapest security coverage available and should run
  continuously regardless of hop progress. **Risk: LOW.**
- **Shrink the surface over time.** The 1,610 modified upstream files are the recurring tax.
  Whenever a fork change can move into its own module, a decorator, a hook, or a setting
  instead of an inline edit to an upstream file, that file stops conflicting permanently.
  Prioritise `modules/backlogs` — it is the hot spot at every single hop.

---

## 9. Emergency lane — critical advisory mid-catch-up

If a severe advisory lands before catch-up completes:

1. Identify the fix commit on `upstream/stable/17` or the current `release/17.x`.
2. `git cherry-pick -x <sha>` onto `epic` (the `-x` records provenance, which helps later
   merges recognise the content).
3. If it does not apply, hand-port it and **record the upstream SHA in the commit message**
   so the later hop that merges it can be resolved knowingly.
4. Expect a conflict when the hop containing that commit is merged; resolve toward
   upstream's version.

**Risk: MEDIUM.** Cherry-picks create duplicate-patch situations that surface as conflicts
later. Acceptable as an exception; not viable as the primary strategy (§2, Option A).

---

## 10. Risk summary

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Backlogs regression (fork's Sprint logic vs upstream Primer migration) | **High** | **High** | Resolve in isolation, dedicated spec run, manual smoke; §5 Step 2 |
| Migration ordering / idempotency failure | Medium | **High** | Dual migration test, empty + restored dump; §6.5 |
| Silent feature duplication (Departments) | **Certain** if undecided | Medium | Decide at 0.6, before Step 4; §5 Step 4 |
| Jira importer mis-resolution | Medium | Medium | Adopt upstream base, pre-written delta list; §6.2 |
| Dropped translation keys | Medium | Low | `i18n-tasks` per hop; §6.1 |
| Ancestry destroyed by squash/rebase | Low | **High** | Merge commits only; §5 |
| Blanket `-X ours/theirs` discarding fork logic | Low | **High** | Prohibited; §6.6 |
| Stalling after 17.2 | Medium | Medium | 17.3 is the hump — treat Steps 2–3 as one unit; §3 |
| Gap widening during execution | **Certain** | Low | ~30 files/month; keep hops moving, re-measure per Appendix A |

---

## Appendix A — how to recompute these numbers

All figures come from conflict-only trial merges that never touch the working tree:

```bash
git fetch upstream --tags --prune

# raw conflicted paths for a target
git merge-tree --write-tree --name-only epic v17.7.1 | tail -n +2 | sed '/^$/,$d'

# conflict types
git merge-tree --write-tree epic v17.7.1 | grep -oE 'CONFLICT \([a-z/ ]+\)' | sort | uniq -c

# decompose into real app code
git merge-tree --write-tree --name-only epic v17.7.1 | tail -n +2 | sed '/^$/,$d' \
  | grep -vE 'config/locales/|^docs/|(^|/)spec/|^\.github/|Gemfile\.lock|Gemfile$|package-lock\.json|^db/migrate|import/jira|jira_' \
  | wc -l
```

`git merge-tree --write-tree` writes only to the object database — safe to run at any time.

## Appendix B — key references

- Fork point: `0774914fa48`
- Baseline tag (create at 0.5): `pre-sync-baseline`
- Upstream security lines: `upstream/stable/17`, `upstream/release/17.7`
- Clean upstream mirror: `origin/dev`
- Feature gating: `lib_static/open_project/feature_decisions.rb`
- Hop targets in order: `v17.1.4` → `v17.2.4` → `v17.3.4` → `v17.4.1` → `v17.5.1` →
  `v17.6.0` → `v17.7.1`
