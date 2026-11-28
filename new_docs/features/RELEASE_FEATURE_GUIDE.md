# Releases — User Guide

Releases let you group work packages into a deliverable, track how ready that deliverable is, and "release" it when it ships — separately from your day‑to‑day Sprints.

A **Release** is a special kind of version. Your existing versions (used as **Sprints**) and your **Releases** are kept as two separate sets, so they never mix in dropdowns, filters, or screens.

---

## Key concepts

- **Sprint** — the work package's built‑in **Version** field (how/when work is done).
- **Release** — a separate **Release** field on the work package (where work is delivered). A work package can belong to **several releases at once** (e.g. a hotfix and the next minor release).
- A Release has a **status**: `open` (not yet released), `locked`, or `closed` (released).
- The **Release field** and the **Version (Sprint) field** are independent: assigning a Release never changes the Sprint and vice versa.

---

## Prerequisites (one‑time, admin)

The **"Release" work package field** is provisioned automatically and is available on all projects and work package types. No setup is needed in most cases.

If it is missing (or you want a second one), an administrator can create it:

1. Go to **Administration → Custom fields → Work packages → + Custom field**.
2. **Format:** `Version`.
3. Enable **Allow multi‑select** (a work package can be in several releases).
4. Set **Version kind** to **Release**.
5. Save, then enable it for the desired **projects** and **types** (or "for all").

> The **Version kind = Release** setting is what makes the field a Release field: it only offers release versions, keeping releases separate from sprints.

---

## Managing releases

Releases are managed per project.

1. Open the project and go to **Project settings → Releases**.
2. Click **New release** to create one. Fill in:
   - **Name** (required, e.g. `v2.4.0`)
   - **Start date** / **Finish date** (optional)
   - **Description** (optional)
   - **Sharing** (optional) — share the release with sub‑projects, the project hierarchy/tree, or **all projects**, exactly like versions. Sharing with **all projects** (system‑wide) is restricted — see *Permissions*.
   - **Wiki page** (optional) — link a wiki page to publish release notes to (see *Release notes*).
3. Use the row actions to **Edit** or **Delete** a release.

> A release's **kind cannot be changed after it is created**. If you created the wrong type, delete it and create the right one. (Your Sprints continue to be managed under **Project settings → Versions**.)

---

## Assigning work packages to a release

Use the **Release** field on the work package:

- **Single work package:** open it and set the **Release** field (you can select more than one release).
- **Several at once:** select the work packages in the work package table → **Bulk edit** → set the **Release** field.

The Release field only offers **release** versions; the built‑in **Version** field only offers **sprint** versions.

### Filtering and views
- Filter work packages by the **Release** custom field in any work package view.
- The built‑in **Version** filter continues to filter by Sprint only.

---

## The release page (readiness)

Open a release (click its name on the **Releases** screen) to see its dashboard:

- **Release readiness** — how many of the release's work packages are done, e.g. `Done: 12 / 20 (60%)`.
- **Work packages** — the work packages assigned to this release (via the Release field), across all projects the release is shared with. If there are many, a **"View all …"** link opens the full, filtered work package view.
- **Release notes** — see below.

---

## Releasing a release

When a release is ready to ship:

1. On the release page, click **Release** (shown for `open` releases).
2. If some work packages are **not yet complete**, choose what to do with them:
   - **Move them to another release** — pick another open release to roll the unfinished work forward into. (Disabled if there is no other open release.)
   - **Remove them from this release** — clears the Release field on those work packages.
   - **Keep them in this release** — leave them attached to the now‑closed release.
3. Confirm. The release is marked **released** (status `closed`).

Notes:
- Only work packages **you can see** are affected, and every change is recorded in each work package's **history**.
- Large releases are processed **in the background**; you'll see a "being processed" message and the result applies shortly after.
- Once released, the release is `closed` and no longer offered for new assignments.

---

## Release notes

On the release page, the **Release notes** section automatically generates notes from the release's **completed** work packages, grouped by type, in Markdown:

```markdown
# v2.4.0

## Feature
- #412 Implement Stripe Elements v3

## Bug
- #501 Fix race condition on webhook
```

- **Copy / export:** select the text in the Release notes box and copy it anywhere.
- **Write to wiki page:** if the release has a **linked wiki page** and you may edit the wiki, click **Write to wiki page "…"**. The notes are inserted (or updated in place on a later run) **without destroying any other content** on that page.

To enable the wiki button, set the release's **Wiki page** field (when creating/editing the release) to the page you want to publish to.

---

## Permissions

| Action | Permission |
| :--- | :--- |
| Create / edit / delete releases, run the Release action | **Manage versions** |
| Share a release with **all projects** (system‑wide) | **Share versions/releases with all projects** (or instance admin) |
| See a release's work packages | **View work packages** |
| Write release notes to a wiki page | **Edit wiki pages** |

Releases follow the same visibility rules as versions, including sharing across projects and visibility through shared work packages.

### Letting project admins share releases with all projects

By default, sharing a release with **all projects** is reserved for instance administrators. To let a project role (e.g. a project admin) do this without granting full admin rights, an instance administrator grants that role the **Share versions/releases with all projects** permission:

1. Go to **Administration → Roles and permissions**.
2. Edit the role (e.g. *Project admin*) and enable **Share versions/releases with all projects**.
3. Save. Members with that role in a project can now pick **All projects** in a release's **Sharing** field.

Until this permission is granted, the **All projects** option stays hidden for non‑admins; the other sharing options (sub‑projects, hierarchy, tree) are unaffected.

---

## Tips & FAQ

- **Sprint vs Release:** the built‑in **Version** field is your Sprint; the **Release** field is your Release. They are deliberately separate and never mix.
- **A work package in several releases:** allowed — the Release field is multi‑select (e.g. a fix that ships in `v1.0.1` and `v1.1.0`).
- **"Roll forward" is greyed out:** there is no other **open** release to move work into — create one first, or choose another option.
- **The Release field shows no options:** make sure at least one **release** exists in the project (Project settings → Releases) and that the Release field is enabled for the project/type.
- **Released by mistake:** edit the release and set its status back to `open` (Project settings → Releases → Edit).
