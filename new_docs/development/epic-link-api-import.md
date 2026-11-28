# Epic Link API Changes for Import

## Purpose

This document explains the API changes that allow importing an Epic relationship for work packages (for example, importing Tasks/Bugs linked to an Epic).

## What Changed

### 1. Data model support for Epic link

Epic linkage is persisted directly on the work package record (`epic_id`), not in the `relations` table.

- Migration: `db/migrate/20260308120000_add_epic_link_to_work_packages.rb`
  - Adds `work_packages.epic_id` (self-reference FK to `work_packages`)
  - Adds `work_package_journals.epic_id` for journaling/history

### 2. Work package API schema exposes `epic`

The V3 schema now exposes `epic` as a linkable field with allowed-value lookup:

- `lib/api/v3/work_packages/schema/work_package_schema_representer.rb`
  - `schema_with_allowed_link :epic`
  - Allowed values endpoint points to:
    - `/api/v3/work_packages/:id/available_relation_candidates?type=epic`

### 3. Work package payload accepts `_links.epic`

`_links.epic.href` can be submitted in create/update payloads:

- `lib/api/v3/work_packages/work_package_representer.rb`
  - Parses `_links.epic.href`
  - Resolves target work package and assigns `represented.epic`

Important: Epic linkage is handled as a work package link field, not as a Relation resource (`/relations`).

### 4. Candidate lookup for `type=epic` is query-engine compatible

To support `available_relation_candidates?type=epic`, the query operator `epic` is registered:

- Added: `app/models/queries/operators/epic.rb`
- Registered in: `app/models/queries/operators.rb`

This prevents invalid-operator failures and enables stable candidate lookup for Epic type.

### 5. Relatable filter logic for Epic candidates

Epic candidates are resolved by dedicated logic:

- `app/models/queries/work_packages/filter/relatable_filter.rb`
  - `operator == "epic"` uses `WorkPackage.relatable_epics_for(source_wp)`
  - Returns only valid Epic targets for the source type

### 6. Validation rules for imported Epic links

Epic assignment is validated in the work package contract:

- `app/contracts/work_packages/base_contract.rb`
  - `epic_id` writable only for Epic-source types (or when clearing existing value)
  - Validates:
    - Epic exists
    - Epic is not self
    - Target is an Epic type
    - Target is visible/authorized

## Import Usage

### 1) Find Epic candidates for a source work package

```bash
curl -sS -H "Authorization: Bearer <TOKEN>" \
  "https://<host>/api/v3/work_packages/<SOURCE_ID>/available_relation_candidates?type=epic&query=<optional>"
```

### 2) Update a work package to link an Epic

```bash
curl -sS -X PATCH \
  -H "Authorization: Bearer <TOKEN>" \
  -H "Content-Type: application/json" \
  "https://<host>/api/v3/work_packages/<SOURCE_ID>" \
  -d '{
    "_links": {
      "epic": { "href": "/api/v3/work_packages/<EPIC_ID>" }
    },
    "lockVersion": <LOCK_VERSION>
  }'
```

### 3) Clear Epic link

```bash
curl -sS -X PATCH \
  -H "Authorization: Bearer <TOKEN>" \
  -H "Content-Type: application/json" \
  "https://<host>/api/v3/work_packages/<SOURCE_ID>" \
  -d '{
    "_links": {
      "epic": { "href": null }
    },
    "lockVersion": <LOCK_VERSION>
  }'
```

## Notes

- `available_relation_candidates` now safely handles edge cases like `query=undefined` for Epic lookups (returns empty list instead of server error).
- This feature intentionally does not create a `Relation` row; Epic is a first-class work package link (`epic_id`).
