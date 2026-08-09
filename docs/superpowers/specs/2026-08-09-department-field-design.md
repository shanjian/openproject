# Department (Organizational Unit) — Design

**Date:** 2026-08-09
**Status:** Draft (pending approval)

## Goal

Add a hierarchical organizational-unit entity for users to this fork,
matching upstream OpenProject's **Departments** feature (shipping in
upstream `dev` ahead of v17.7.0; this fork is based on v17.3.0, so the
feature doesn't exist here yet). A user requested this as an
"Organizational Unit" field type; research showed OpenProject core
already built exactly this concept, calling it "Department."

## Naming

The name "Department" reads as narrower than the actual concept (any
nested org unit, not just literal company departments), but it is kept
**everywhere** — model/table/route/class names AND user-facing UI copy —
to match upstream 1:1 and minimize merge/sync friction with future
upstream releases. No fork-specific renaming.

## Scope

**In scope:** the core Department entity, its hierarchy, the admin CRUD
UI, and its use as a user attribute (profile, hover card, edit form).

**Out of scope (explicitly deferred):** upstream's `modules/ldap_departments`
LDAP/AD auto-sync engine. That module is ~2x the size of the core feature
(116 files / 7,760 LOC upstream) and is only useful if this deployment
wants department hierarchy pulled automatically from an LDAP directory.
Not needed now; can be a separate future port if that need arises.

**Feature gating:** upstream ships this behind a rollout feature-decision
flag (separate from the real Enterprise gate on LDAP sync, which doesn't
apply here since LDAP sync is out of scope). This fork enables the core
feature unconditionally — no flag, no EE-token check — consistent with how
this fork treats its other custom features.

## Source of truth

This is a **port/adapt of upstream's real implementation**, not a
from-scratch design. Upstream commit range (on `upstream/dev`, not yet
tagged into a release as of this writing):

- First commit: `df949c1ac20` "Introduce Departments area of the user
  management" (2026-03-16)
- Last core-feature commit: `d7bc648642c` "[OP-19617] Cover the turbo#1300
  back-button fix" (2026-06-27)
- ~28 commits touch the core feature (excluding the 34 commits scoped to
  `modules/ldap_departments`, which are out of scope per above)
- Core feature diff: 41 files changed, 3,841 insertions

The fork diverged from `upstream/dev` on 2026-02-26 (merge-base
`0774914fa48`), **before** Departments was introduced, so none of this
exists on `epic` yet. The fork's `group.rb`, `user.rb`, and `principal.rb`
have since diverged moderately from that pre-Department baseline (~100
lines across the 3 files, from this fork's own unrelated feature work), so
porting will hit conflicts in those specific files. The upstream commits
are small and atomic (one concern each), so conflicts are resolved
incrementally rather than as a single large merge.

## Data model

Reuses the existing `Group` STI subtype of `Principal` (`users` table)
rather than introducing a new top-level entity:

- New `group_details` table (1:1 with a `Group` via `principal_id`):
  - `organizational_unit` boolean, default `false` — distinguishes a
    Department from a plain Group
  - `parent_id` (references `users`, i.e. another `Group`/Department) —
    self-referential adjacency list, giving arbitrary-depth nesting (e.g.
    `IT / Development / Frontend`). Not `closure_tree` — a plain
    parent pointer, walked recursively, unlike this codebase's existing
    `hierarchy` custom-field format.
  - `timestamps`
  - Unique index backing name-uniqueness scoped to siblings (not global)
- New `HasPrincipalDetails` concern mixed into `Group` (and referenced
  from `Principal`) exposing the `organizational_unit`/`parent`
  accessors and hierarchy helpers (move-to-new-parent, delete-and-reparent-
  children).
- `User` gets `has_many :departments` (through group membership, scoped to
  `organizational_unit: true` groups) and a `#department` convenience
  method returning the single department a user belongs to (a user
  belongs to **at most one** department — enforced at the service layer,
  not a DB constraint, matching upstream).

A one-time data migration backfills `group_details` rows for all existing
`Group` records (`organizational_unit: false`), so existing groups are
unaffected.

## Backend components

- `Admin::DepartmentsController` — CRUD, add/remove user, change-parent
  actions, rendered via Turbo Frames (not a full-page reload per action).
- `app/components/admin/departments/*` — ~9 ViewComponents: page header,
  add-department form, add-user form, detail view, blankslate (empty
  state), hierarchy layout, change-parent dialog, move-user dialog, row
  components for department/user listings.
- `app/services/departments/{add_user,remove_user}_service.rb` — service
  objects enforcing the "one department per user" invariant and producing
  `ServiceResult`, per this repo's existing service-object convention.
- Contracts: name-uniqueness scoped to siblings; parent-change validation
  (no cycles).
- `db/migrate/*_add_department_to_default_user_custom_field_section.rb` —
  backfills "Department" into the default user-attribute section so it
  shows up alongside other built-in user fields without extra admin
  configuration.
- Demo data seeder (`app/seeders/demo_data/department_seeder.rb`) for
  local/dev environments.

## Frontend / UI

- Admin nav entry under Administration → Users and permissions →
  Organization.
- User profile: department shown with a briefcase icon.
- User hover card: department shown (existing hover-card component gets a
  conditional row).
- User edit form: department select (disabled/read-only if the department
  were LDAP-managed — not applicable here since LDAP sync is out of
  scope, so this becomes a plain editable select).
- No Angular/legacy field-type work needed — this is a native
  Rails/Hotwire/ViewComponent feature, not a custom-field format, so the
  `IFieldType`/`EditFieldService` frontend registration system (relevant
  for custom fields, not built-in user attributes) is untouched.

## Testing

Port upstream's spec coverage, adapted to this fork's conventions:

- Model specs: `group_detail_spec.rb`, `has_principal_details_spec.rb`
- Service specs: `add_user_service_spec.rb`, `remove_user_service_spec.rb`
- Feature specs using `spec/support/pages/admin/departments.rb` (page
  object), adapted to this fork's existing Capybara page-object patterns
- Seeder spec: `department_seeder_spec.rb`

## Rollout / migration safety

- Additive migration (`create_table :group_details` + backfill insert +
  index) — no destructive changes to `users` or `groups`.
- No existing feature in this fork touches `GroupDetail`/department
  concepts, so no conflicting in-flight work to reconcile beyond the
  `group.rb`/`user.rb`/`principal.rb` merge conflicts noted above.

## Effort estimate

Porting/adapting upstream's ~28 commits (schema → model → admin UI → user
integration → seeders/specs → strip rollout flag), resolving conflicts
against this fork's existing model customizations, verifying under this
fork's pinned Ruby 3.4.7 / Rails 8.0.3:

**~3–5 focused engineer-days.**

Reimplementing from scratch instead (not recommended) would cost roughly
2x that (~7–10 days) for no benefit, since the design, UX copy, and edge
cases are already solved and reviewed upstream.

## Open risks

- Upstream commits live on `upstream/dev`, not yet in a tagged release —
  they could still change before upstream's actual v17.7.0 ships. Low risk
  since departments have already been through several rounds of upstream
  review (Primer UI passes, flakiness fixes) and are far along.
- Conflict resolution in `group.rb`/`user.rb`/`principal.rb` requires
  understanding this fork's existing customizations well enough to merge
  correctly rather than blindly taking one side.
