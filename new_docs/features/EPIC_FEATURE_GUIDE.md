# Epics — User Guide

**Epics** let you group related work packages (Tasks, Bugs, Stories) under one larger initiative — independently of the parent/child hierarchy. This is the same idea as an "Epic" in Jira: a single, simple **Epic** field on a work package that says "this work belongs to that initiative", and an aggregated view on the Epic itself that lists everything assigned to it.

---

## Key concepts

- An **Epic** is a work package of type **Epic**.
- Other work packages link to it through a dedicated **Epic** field — not through the **Parent** field. The two are independent: setting an Epic never changes the parent, and vice‑versa.
- The Epic link is **cross‑project**: a Task in Project A can belong to an Epic in Project B.
- Only certain types can *carry* an Epic link: **Task, Bug, Story, User story**. Only the **Epic** type can *be* an Epic.

---

## Linking a work package to an Epic

On a Task, Bug, or Story:

1. Open the work package.
2. Find the **Epic** field (it sits with the other attributes, next to fields like Parent and Version).
3. Click it and pick an Epic from the autocomplete. You can choose an Epic from **any project you can see**, not just the current one.
4. To remove the link, clear the **Epic** field.

You can also set it in **bulk edit** from the work package table, like any other field.

> The **Epic** field only appears (and is editable) on Task, Bug, Story and User story work packages. On other types it is not shown.

---

## Seeing everything in an Epic

Open the Epic work package itself. It shows an **Issues in Epic** section — an embedded table listing every work package linked to this Epic, across all projects. It's a read‑only roll‑up so you can see the whole initiative at a glance.

---

## Filtering by Epic

You can filter any work package view by **Epic**. There are two ways the filter can behave:

- **Across projects (default)** — shows work packages linked to the chosen Epic **regardless of which project they live in**. This is the natural choice because Epic links are cross‑project. In the filter operator menu this is *"is (across projects)"*.
- **Within the current project** — the stricter `is` operator, which only returns matches inside the current project/query scope.

This is especially useful on **boards**: filter a board to an Epic and see all of that Epic's work, even when the cards come from several projects.

---

## Importing / setting the Epic via the API

The Epic link is exposed in the API v3 as a linked resource, `epic` (similar to `parent`). This is handy for migrations (e.g. importing from Jira).

- **Find candidate Epics** for a work package:

  ```
  GET /api/v3/work_packages/<ID>/available_relation_candidates?type=epic
  ```

- **Link an Epic:**

  ```http
  PATCH /api/v3/work_packages/<ID>
  Content-Type: application/json

  {
    "_links": { "epic": { "href": "/api/v3/work_packages/<EPIC_ID>" } },
    "lockVersion": <LOCK_VERSION>
  }
  ```

- **Unlink** by sending `"epic": { "href": null }`.

See `new_docs/development/epic-link-api-import.md` for the full import notes.

---

## Permissions

| Action | Permission |
| :--- | :--- |
| Set / change / clear the Epic field | **Edit work packages** |
| See an Epic and its issues | **View work packages** |

There is no separate "Epic" permission — it follows normal work‑package edit/view rights, and respects cross‑project visibility.

---

## Tips & FAQ

- **Epic vs. Parent:** Parent builds the work breakdown structure (sub‑tasks). Epic groups work under an initiative and works across projects. Use both together if you like.
- **The Epic field is missing on a work package:** it only shows on Task, Bug, Story and User story. Other types don't carry an Epic link.
- **An Epic from another project doesn't show in my board:** make sure the Epic filter is using the **"is (across projects)"** operator, not the project‑scoped `is`.
- **Validation error "must be of type Epic":** the work package you picked isn't an Epic — only Epic‑type work packages can be linked.
