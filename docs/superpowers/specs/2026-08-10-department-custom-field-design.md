# Department Custom Field Format — Design

**Date:** 2026-08-10
**Status:** Draft (pending approval)

## Goal

Add a new custom field format, **"Department"**, selectable in the
standard "new custom field" admin flow (alongside `list`, `version`,
`hierarchy`, etc.) and attachable to work package types. Its value is a
single reference to a `Group` where `organizational_unit? == true` — the
same org-unit tree introduced by the Department admin feature (PR #100:
`Groups::Hierarchy`, `Group.organizational_units`, the `/departments`
admin UI). One tree, two consumers: "which department is this user in"
(already shipped) and now "which org unit does this Objective/Key Result
belong to" (this feature).

## Motivating use case

OKR tracking: Objectives and Key Results are work packages (custom WP
types "Objective"/"Key Result"). Each one belongs to a single
organizational unit — company, department, or team, all modeled as nodes
at different depths of the same `Group` tree. Reporting needs to filter
and group the work package table by this field.

## Requirements (confirmed)

- Selectable as a custom field **format**, not a one-off hard-wired field
  — reusable the way `list`/`version`/`hierarchy` are.
- **Single-select.** One Objective/KR has exactly one org unit.
- Any node in the tree is selectable — root ("Company"), mid-level
  ("Department"), or leaf ("Team"). No leaf-only restriction.
- **Optional.** Not required on Objective/KR — existing items don't need
  retroactive backfill before this ships.
- Admin activates it on **Objective + Key Result** work package types
  via the existing, standard custom-field-to-type mechanism (no new
  activation UI needed — this is how every custom field already works).
- **Filtering and grouping are required** in the work package table —
  this is the actual point of the feature (OKR dashboards sliced by org
  unit).
- **Exact-match only for now.** Filtering/grouping by "Engineering" does
  **not** roll up its child teams' items. Confirmed acceptable for v1,
  but rollup is an explicitly anticipated v2 — see "Built for extension"
  below for how the design keeps that cheap to add later.

## Why this shape, not a clone of `hierarchy`

The existing `hierarchy` custom field format has its own model
(`CustomField::Hierarchy::Item`), its own per-custom-field admin tree
builder, and is Enterprise-gated (`enterprise_feature:
:custom_field_hierarchies`) for the *create/manage* flow. None of that
fits: we don't want a second, disconnected tree to maintain, and we don't
want to depend on an EE token existing.

`department` is architecturally closer to `version` — a flat reference
to *another table's existing rows* — with the tree flattened into a
breadcrumb-style label for display, exactly how `hierarchy` fakes tree
display today (`Item#ancestry_path` joins ancestor names with `" / "`;
there is no real indented tree-picker even for `hierarchy` — confirmed by
reading `edit-field.initializer.ts` and the hierarchy value-edit path).
So `department` gets the same UX `hierarchy` already has, for
meaningfully less new code, by reusing `Group#ancestors`/
`#hierarchy_depth` instead of building anything new.

Confirmed via code reading: the Enterprise gate on `hierarchy` sits only
on `CustomFieldsController#validate_enterprise_token` (creating/editing
the field definition) and the admin item-management screens — never on
`CustomValue::HierarchyStrategy`, the API v3 injector, or the Angular
edit widget. `department` doesn't touch any of those gated paths anyway,
so no EE dependency is introduced either way.

## Architecture

| Layer | New code | Mirrors |
|---|---|---|
| Format registration | `config/initializers/custom_field_format.rb`: `department` entry, `only: %w(WorkPackage)`, `multi_value_possible: false`, `formatter: "CustomValue::DepartmentStrategy"` | `version` entry |
| Value storage/casting | `app/models/custom_value/department_strategy.rb`, `CustomValue::DepartmentStrategy < CustomValue::ARObjectStrategy`, `ar_class` → `Group` | `CustomValue::VersionStrategy` |
| Possible values / label | Branch in `app/models/custom_field.rb` (mirrors the existing `hierarchy` branch): `Group.organizational_units.in_tree_order`, label = ancestor-joined breadcrumb (`Group#ancestors` + own name) | `custom_field_hierarchy_items` |
| Filtering | **Dedicated** `app/models/queries/filters/shared/custom_fields/department.rb` (own class, not a case-branch inside `ListOptional`) — exact match (`custom_values.value IN (...)`) | `Queries::Filters::Shared::CustomFields::Hierarchy` (dedicated class, not the shared generic one) |
| Grouping | `join_for_order_by_department_sql` in `CustomField::OrderStatements`; add `"department"` to the `can_be_used_for_grouping?` whitelist | pattern used by `list`-style formats (`version` is currently *excluded* from grouping — `department` won't be) |
| API v3 | Entries in `lib/api/v3/utilities/custom_field_injector.rb`'s `LINK_FORMATS`/`NAMESPACE_MAP`/`REPRESENTER_MAP`, pointing at the **existing** `API::V3::Groups::GroupRepresenter` (built for PR #100 — no new representer) | `version`'s entries |
| Angular | One entry in `edit-field.initializer.ts` mapping `'Group'` → the existing `SelectEditFieldComponent` (flat dropdown, same as `version`/`hierarchy` today) — **no new component** | `version`/`hierarchy`'s entries |
| Locale | `label_department: "Department"` (format-picker label, singular) — verified no collision with PR #100's `label_departments` (plural, the admin menu label) or its `departments.*` namespace | `label_hierarchy`/`label_list` |

### Built for extension (rollup, v2)

Filtering gets its **own** filter class instead of a branch inside the
shared `ListOptional` class specifically so that swapping exact-match for
descendant-inclusive matching later is a change contained to one file:
replace the `IN (id)` condition with a recursive-descendant subquery
(the same CTE approach `Groups::Hierarchy#descendant_ids` already uses),
without touching the generic filter machinery `list`/`version` also rely
on. Grouping's join method is similarly isolated. No rollup code is
written now — this is purely about not painting the exact-match decision
into shared code that other formats depend on.

## Data flow

1. Admin creates a custom field, format "Department", activates it on
   the Objective and Key Result work package types (standard flow).
2. On a WP edit form, the field renders as a flat `SelectEditFieldComponent`
   dropdown populated from `Group.organizational_units.in_tree_order`,
   each option labeled with its breadcrumb path (e.g. "Engineering /
   Frontend").
3. Selecting a value stores that Group's id as `CustomValue#value`
   (string column, no DB-level FK — consistent with every other
   reference-type custom field).
4. Read path: `DepartmentStrategy#typed_value` → `Group.find_by(id:
   value)`; `formatted_value` renders the breadcrumb label, with a
   graceful "not found" fallback if the referenced Group is gone (same
   fallback `hierarchy` already uses for its own dangling references).
5. API v3: the WP resource exposes `_links.customFieldN` →
   `{href: api_v3_paths.group(id), title: <breadcrumb>}`, rendered via
   `GroupRepresenter`.
6. Filtering: WP table filter "Department" offers a multi-select of
   available Groups; matches only the exact selected id(s).
7. Grouping: "group by Department" groups on the referenced Group id,
   using the breadcrumb label as the group header.

## Error handling

- **Referenced Group deleted while in use:** `CustomValue.value` has no
  DB-level foreign key (true for every reference-type custom field, not
  specific to this one). `typed_value`/`formatted_value` degrade
  gracefully (nil / "not found" label) rather than raising — matching
  existing `version`/`hierarchy` behavior when their referenced row
  disappears. No new handling needed; this is accepted, pre-existing
  behavior across the custom field system.
- **Write-time validation:** `validate_type_of_value` checks the
  submitted id is currently in `custom_field.possible_values(customized)`
  — a user cannot set a stale/deleted department going forward; only a
  value set *before* its Group was deleted becomes stale, same as
  `version`.

## Testing

- `CustomValue::DepartmentStrategy` — cast/format/validate, including the
  "referenced Group deleted" fallback.
- `CustomField` — `possible_values`/`cast_value` branch for `"department"`.
- `Queries::Filters::Shared::CustomFields::Department` — exact-match
  filtering.
- `CustomField::OrderStatements` — grouping join.
- API v3 request spec — WP resource exposes/accepts the department link,
  reusing `GroupRepresenter`.
- End-to-end request/feature spec — admin creates the field, activates it
  on Objective + Key Result types, sets a value on a work package,
  filters and groups the WP table by it.

## Non-goals (this iteration)

- Descendant-rollup filtering/grouping (planned v2, see "Built for
  extension" above).
- Project-level attachment (`only:` starts scoped to `WorkPackage`;
  extending to `Project` later is a one-line change to the format
  registration if needed).
- Any change to the existing Department admin UI, org-chart, or
  user-attribute feature (PR #100) — this feature only *reads* that tree.
