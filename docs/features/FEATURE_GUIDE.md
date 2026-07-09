# Custom Features Guide

This guide documents the features and behavior changes added **on top of OpenProject 17.1.2** in this build. Each section is self‑contained — read or search for just the one you need.

Some larger features have their own dedicated guides:

- **[Releases](RELEASE_FEATURE_GUIDE.md)** — group work packages into a deliverable, track readiness, and ship it (separate from Sprints).
- **[Epics](EPIC_FEATURE_GUIDE.md)** — group work packages under an initiative, across projects (Jira‑style Epic link).
- **[Create a GitLab branch from a work package](GITLAB_CREATE_BRANCH_FEATURE_GUIDE.md)** — one‑click branch creation in GitLab, named after the work package.

Everything else is below.

---

## Contents

- [Boards available to everyone](#boards-available-to-everyone)
- [Kanban quick filters (Assignee & Version)](#kanban-quick-filters-assignee--version)
- [Assignee board totals](#assignee-board-totals)
- [Backlogs: Inbox column](#backlogs-inbox-column)
- [Backlogs: orphan tasks in columns](#backlogs-orphan-tasks-in-columns)
- [Backlogs: large‑board performance & column limit](#backlogs-large-board-performance--column-limit)
- [Roadmap counts your "Done" statuses](#roadmap-counts-your-done-statuses)
- [Sprint wiki link fixes](#sprint-wiki-link-fixes)
- [Story points on every work package type](#story-points-on-every-work-package-type)
- [Default description templates for Bug & Task](#default-description-templates-for-bug--task)
- [API additions](#api-additions)

---

## Boards available to everyone

All board types are now available without an Enterprise license. Previously only the **Basic** board was free in Community Edition; the automated boards were locked.

You can now create any of these from **Project → Boards → + Board**:

- **Basic** — a blank board; add cards and columns by hand.
- **Status** (Kanban) — columns follow work package status; dragging a card changes its status.
- **Assignee** — one column per person; dragging reassigns.
- **Version** — one column per version; dragging changes the version.
- **Subproject** — one column per subproject; dragging moves the work package between projects.
- **Parent‑child** — columns by parent; dragging re‑parents the work package.

The "Boards are an Enterprise add‑on" upsell banners on the board creation form and board page have been removed.

---

## Kanban quick filters (Assignee & Version)

On **Status (Kanban) boards**, two quick‑filter dropdowns appear above the board:

- **Assignee** — *All assignees* / *Unassigned* / each person.
- **Version** — *All versions* / *No version* / each version.

Pick a value to instantly narrow the board. These filters are temporary — they don't change the board's saved filters, so they're a fast way to focus without reconfiguring anything.

---

## Assignee board totals

On **Assignee boards**, each column (each person) shows running totals under the header:

- **Story points** — sum of story points of the cards in that column.
- **Work** — sum of estimated time (hours).

Rows only appear when there's something to sum. Drag a card from one person to another and both columns' totals update immediately — handy for balancing workload at a glance.

---

## Backlogs: Inbox column

The Backlogs board has a new **Inbox** column for work that hasn't been planned yet.

- It collects work packages that have **no version / sprint assigned**.
- Only **Story and Task** types appear there (the same types you'd drag into a sprint), so it stays focused on actionable items.
- A **Include closed** checkbox in the column header toggles whether closed items show. The default is **off** (open work only); your choice is remembered across reloads and back/forward navigation.
- Drag items straight from the Inbox into a sprint or the product backlog.

When empty it reads: *"Work packages with no version or sprint assigned will appear here."*

---

## Backlogs: orphan tasks in columns

Tasks that have **no parent story** now appear as first‑class rows in the backlog and sprint columns (not only in the Inbox), so they can't get lost.

To reflect this, the column counters changed wording from *"… stories in sprint"* to *"… items in sprint"* — the count now reflects every item in the column, including orphan tasks alongside stories.

---

## Backlogs: large‑board performance & column limit

Several changes keep large backlogs (thousands of items) responsive:

- **Column limit:** each column shows at most **200 items**. If there are more, a banner appears: *"Showing the first 200 items. Narrow the column (assign items to versions, or close completed work) to see the rest."* Nothing is deleted — reduce the column to reveal the rest.
- **Lazy row menu:** the per‑story "⋯" menu (Open details, Open fullscreen, Move to top/up/down/bottom) now loads the first time you open it instead of on every page load. Expect a tiny delay on first open in exchange for a much faster initial board.
- **Faster queries:** Inbox and column loading were optimized (lighter preloading and native sorting) to avoid stalls on big boards.

---

## Roadmap counts your "Done" statuses

The project **Roadmap** now treats work packages in any of your configured **Done statuses** as 100% complete — not just statuses flagged as "closed".

This affects the progress bar, the open/closed counts, the "days remaining" estimate, and version auto‑close. If your workflow's *Done* status isn't marked closed, the roadmap now reports progress correctly instead of undercounting it.

---

## Sprint wiki link fixes

Two fixes to the **Wiki** action in the sprint/backlog menus:

- It now works for **view‑only users** — the link points to the wiki page itself (view route) instead of the edit route, so people without edit rights can open it.
- Opening it on a project **without a wiki** now shows a clean **404 Not Found** instead of erroring.

---


## Story points on every work package type

**Story points** are no longer limited to backlog story types. The field is now available on **all work package types** (Tasks, Bugs, Epics, etc.) in forms, filters/columns, and the API.

Backlog ranking is unchanged — only story types are positioned in backlogs — but you can now estimate any kind of work in points.

---

## Default description templates for Bug & Task

New **Bug** and **Task** work packages start with a structured description template, so reporters fill in the right information.

- **Task** template: *Summary, Goal / Expected outcome, Scope (in/out), Acceptance criteria, Dependencies / Links.*
- **Bug** template: *Summary, Environment, Steps to reproduce, Expected behavior, Actual behavior, Reproducibility, Evidence, Impact.*

You can edit or clear the text before saving. Admins can change a template at **Administration → Work packages → Types → (Bug/Task) → Default text** (the type's description field). Existing installations were backfilled automatically — but only where a type's default description was still empty, so any template you'd already customized was left untouched.

---


## API additions

- **Active versions filter:** `GET /api/v3/projects/:id/versions?active=true` returns only **open** versions (excludes locked/closed). Composes with pagination — handy for integrations that only want assignable versions.
- **Epic link:** the `epic` linked resource on work packages — see the **[Epics guide](EPIC_FEATURE_GUIDE.md)**.
- **`/api/v3/roles` for admins:** global admins can now reach the roles endpoint even with no project memberships (previously returned 403).

---

*For migrations from Jira, operations‑level backfill scripts (users/groups, project memberships, comment history, DB backup/restore) live under `script/` and `docs/` — these are admin tooling, not end‑user features.*
