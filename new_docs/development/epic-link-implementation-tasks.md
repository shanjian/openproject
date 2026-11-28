# Epic Link Feature Implementation Tasks

## Goal

Implement a Jira-like Epic link in OpenProject where:

- A Task/Bug can be linked to one Epic.
- An Epic can show all linked Task/Bug work packages.
- This link is independent of parent-child hierarchy.

## Scope and intent

This document defines implementation tasks for a **custom Epic link feature** (Option 3), using a dedicated `epic_id` on work packages.

Out of scope:

- Replacing existing parent-child hierarchy behavior.
- Estimation or scheduling details.

## Product decisions to confirm before coding

1. Which source types can link to an Epic (`Task`, `Bug`, `Story`, etc.)?
A: These 3 should be enough (Task, Bug, Story)
2. Which target type(s) are valid Epic targets (`Epic` only, or configurable)?
A: Epic only
3. Must Epic and linked issue be in the same project?
A: No
4. Should a work package be allowed to have both `parent` and `epic` simultaneously?
A: Yes
5. Should we auto-migrate any existing parent links into Epic links?
A: No

## Implementation tasks

## 1. Data model and migration

### Task 1.1: Add `epic_id` to `work_packages`

- Add nullable `epic_id` column to `work_packages`.
- Add database index on `epic_id`.
- Add foreign key constraint to `work_packages(id)`.

Acceptance criteria:

- Schema migration runs cleanly.
- DB enforces referential integrity.

### Task 1.2: Add model associations

- In `WorkPackage`, add:
  - `belongs_to :epic, class_name: "WorkPackage", optional: true`
  - `has_many :epic_issues, class_name: "WorkPackage", foreign_key: :epic_id, inverse_of: :epic`

Acceptance criteria:

- `wp.epic` and `epic.epic_issues` resolve correctly.

Suggested touchpoint:

- `app/models/work_package.rb`

## 2. Domain validation and permissions

### Task 2.1: Add contract attribute and validation

- Add `epic_id` as writable attribute in work package contracts.
- Validate:
  - Epic exists.
  - Epic is visible to current user.
  - Epic target has allowed type(s).
  - Work package cannot link to itself.
  - Optional: no cross-project links unless setting allows it.

Acceptance criteria:

- Invalid Epic links are rejected with clear errors.
- Valid links save via create/update flows.

Suggested touchpoints:

- `app/contracts/work_packages/base_contract.rb`
- `app/contracts/work_packages/update_contract.rb`

### Task 2.2: Define permission model for editing Epic link

- Reuse existing permission if acceptable (e.g. `manage_subtasks` or `edit_work_packages`), or introduce a dedicated permission.
- Apply consistently in form/schema writability.

Acceptance criteria:

- Users without permission cannot set/change Epic link.

## 3. API and schema exposure

### Task 3.1: Expose `epic` linked resource in WorkPackage API

- Add associated linked resource for `epic`.
- Add setter parser from HAL link.
- Handle hidden/invisible Epic similarly to `parent`.

Acceptance criteria:

- `GET /api/v3/work_packages/:id` includes `_links.epic` when present.
- `PATCH` can set/unset Epic.

Suggested touchpoint:

- `lib/api/v3/work_packages/work_package_representer.rb`

### Task 3.2: Add `epic` to schema and forms

- Add `schema_with_allowed_link :epic, type: "WorkPackage"`.
- Provide allowed-values endpoint callback for autocompletion candidates.

Acceptance criteria:

- Work package form schema reports `epic` correctly.
- UI can resolve allowed candidates from schema link.

Suggested touchpoint:

- `lib/api/v3/work_packages/schema/work_package_schema_representer.rb`

### Task 3.3: Ensure payload parsing updates `epic`

- Confirm payload representer accepts `epic` link in create/update payload.

Acceptance criteria:

- API and UI form submission both persist Epic link.

Suggested touchpoint:

- `lib/api/v3/work_packages/work_package_payload_representer.rb`

## 4. Query and filtering support

### Task 4.1: Add `Epic` filter

- Add a work package filter class (by `epic_id`) similar to `ParentFilter`.
- Register filter in query registration.

Acceptance criteria:

- Users can filter work packages by Epic in table/query UI and API.

Suggested touchpoints:

- `app/models/queries/work_packages/filter/`
- `app/models/queries/work_packages.rb`

### Task 4.2: Add `Epic` column/select

- Add selectable query column for Epic.
- Ensure sorting and grouping behavior is defined.

Acceptance criteria:

- Users can insert `Epic` column into work package table.

## 5. Single-view UI behavior

### Task 5.1: Render and edit Epic field on issue work packages

- Make `epic` available as editable field in single view based on schema.
- Ensure autocomplete and display rendering work for linked work package.

Acceptance criteria:

- Task/Bug form shows Epic field when configured/available.
- Users can set, change, remove Epic link.

Suggested touchpoints:

- `frontend/src/app/features/hal/services/hal-resource.config.ts`
- `frontend/src/app/features/hal/resources/work-package-resource.ts`
- `frontend/src/app/shared/components/fields/edit/field-types/work-package-edit-field.component.ts`

### Task 5.2: Show “Issues in Epic” on Epic detail view

- Add section or group in Epic details to list linked work packages.
- Support filtering by relevant types (Task/Bug/etc.).
- Support navigation to linked issues.

Acceptance criteria:

- Epic page displays linked issues list.
- List updates after linking/unlinking.

## 6. Optional admin settings

### Task 6.1: Add feature setting toggles

- Toggle feature globally (or by project/module).
- Optional setting for allowed source/target types.

Acceptance criteria:

- Feature can be enabled/disabled without code changes.

## 7. Data migration support (optional but recommended)

### Task 7.1: Backfill script/rake task

- Add a rake task to map legacy links into `epic_id` (if needed).
- Include dry-run mode and conflict report.

Acceptance criteria:

- Migration can be previewed safely.
- Applied migration is idempotent or clearly one-time.

Suggested touchpoint:

- `lib/tasks/work_packages.rake`

## 8. Test coverage tasks

### Task 8.1: Backend unit/model/contract specs

- Work package association specs.
- Contract validation specs for all failure/success cases.

### Task 8.2: API request specs

- Show/update/create behavior for `epic`.
- Permission and visibility behavior.

### Task 8.3: Query/filter specs

- `Epic` filter behavior and SQL.
- Column rendering and query serialization.

### Task 8.4: Frontend specs

- HAL parsing for `epic`.
- Field edit behavior.
- Epic detail linked-issues section behavior.

Acceptance criteria:

- Regressions are caught in model/API/UI flows.

## 9. Documentation tasks

### Task 9.1: User guide docs

- How to link Task/Bug to Epic.
- How to view “Issues in Epic”.
- How to filter by Epic in work package table.

Suggested touchpoints:

- `docs/user-guide/work-packages/work-package-relations-hierarchies/README.md`
- `docs/user-guide/work-packages/work-package-table-configuration/README.md`

### Task 9.2: API docs

- Add `epic` linked property in API docs/examples.

Suggested touchpoints:

- `docs/api/apiv3/tags/work_packages.yml`
- Related OpenAPI examples in `docs/api/apiv3/components/examples/`

## 10. Rollout and quality gates

### Task 10.1: Pre-merge checklist

- Migration reviewed.
- Permission model reviewed.
- Query/filter performance validated on realistic data.
- Docs updated.

### Task 10.2: Post-merge verification checklist

- Create Task/Bug and link to Epic.
- Open Epic and confirm linked issue list is correct.
- Test unlink/relink behavior.
- Validate API parity with UI actions.

## Risks and mitigations

1. Risk: Confusion between `parent` and `epic` semantics.
Mitigation: Explicit labels/help text and docs, plus validation rules.

2. Risk: Cross-project visibility leaks.
Mitigation: Reuse visibility checks from `parent` representer pattern.

3. Risk: Query performance on large datasets.
Mitigation: DB index on `epic_id`, query-level spec coverage, benchmark on staging-like data.

4. Risk: Incomplete UI wiring for new linked resource.
Mitigation: Update HAL attr type mappings and add frontend integration tests.

## Definition of done

- Epic link can be set/unset from issue work packages.
- Epic detail view displays linked issues list.
- API supports read/write of Epic link.
- Query/filter support is available in tables.
- Tests and documentation cover the feature behavior.

## Implementation status (current branch)

The following has been implemented in code:

- `epic_id` support added through a migration for `work_packages` and `work_package_journals`.
- `WorkPackage` model now supports:
  - `belongs_to :epic`
  - `has_many :epic_issues`
- Contract-level support for `epic_id`:
  - writable only for selected source types (`Task`, `Bug`, `Story`/`User story`)
  - validation for existence, visibility, self-link prevention, and Epic target type
- API V3 support:
  - `_links.epic` in work package representer
  - payload parsing for setting/unsetting epic
  - schema support with allowed-values link for `epic`
- Candidate lookup support:
  - `available_relation_candidates?type=epic` now supported
  - source-type and target-type filtering enforced
- Query support:
  - new `Epic` filter (`epic_id`)
  - new `Epic` table column/select
  - schema dependency representer for the new filter
- Frontend wiring:
  - HAL resource config and work package resource include `epic`
  - work package edit field fetches allowed values for `epic` like `parent`
- Epic detail behavior:
  - relations tab now shows an additional group for Epic work packages:
    - **Issues in epic**

## Product decisions applied

- Source types allowed to set Epic link: `Task`, `Bug`, `Story` (including `User story` naming variant)
- Target type allowed: `Epic` only
- Cross-project Epic links: allowed
- Parent + Epic at the same time: allowed
- Automatic migration from parent-child links: not implemented

## Further decisions needed

- Should unlinking issues from an Epic be possible directly from the Epic relations tab action menu (currently not exposed there)?
- Should source/target type sets become admin-configurable instead of code-defined?
- Should we add a dedicated global feature flag/module toggle for Epic link?
- Should project-copy behavior retain, remap, or clear `epic_id` links on copied work packages?

## Next actions

- Run DB migration in target environment and verify schema update.
- Run full backend/frontend test suites in a DB-enabled environment.
- Add/adjust user-facing docs under:
  - `docs/user-guide/work-packages/work-package-relations-hierarchies/README.md`
  - `docs/user-guide/work-packages/work-package-table-configuration/README.md`
- Add API docs/examples updates for `_links.epic` and filtering by Epic.
