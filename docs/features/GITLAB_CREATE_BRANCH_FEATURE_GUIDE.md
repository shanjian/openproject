# Create a GitLab branch from a work package

This build adds a **Create branch in GitLab** button to a work package's GitLab
tab. One click creates a branch — named after the work package — directly in the
GitLab project you've linked, as *you* (using your own GitLab token).

Previously the GitLab tab could only **copy** a branch name to your clipboard;
you still had to switch to GitLab (or a terminal) to actually create the branch.

> This guide doubles as a verification checklist. Follow the **Setup** once, then
> run **[Verify end‑to‑end](#verify-end-to-end)** to confirm the feature works.

---

## Contents

- [How it works (at a glance)](#how-it-works-at-a-glance)
- [Setup (one time)](#setup-one-time)
  - [1. Administrator — GitLab instance URL](#1-administrator--gitlab-instance-url)
  - [2. Project admin — link the GitLab project](#2-project-admin--link-the-gitlab-project)
  - [3. Each user — add your GitLab token](#3-each-user--add-your-gitlab-token)
- [Using it](#using-it)
- [Verify end‑to‑end](#verify-end-to-end)
- [How the branch is named](#how-the-branch-is-named)
- [Troubleshooting](#troubleshooting)
- [Notes & limitations](#notes--limitations)

---

## How it works (at a glance)

Three pieces of configuration, set once, combine at click time:

| Layer | Who sets it | What |
|---|---|---|
| **GitLab instance URL** | Administrator | The single GitLab server every request goes to |
| **GitLab project mapping** | Project admin | Which GitLab project this OpenProject project creates branches in |
| **Personal access token** | Each user | Your own GitLab token, so branches are created as you |

When you click the button, OpenProject calls GitLab's API to create the branch,
starting from the project's default branch (unless a start branch is configured).

---

## Setup (one time)

### 1. Administrator — GitLab instance URL

1. Go to **Administration → Plugins** (direct URL: `/admin/settings/plugin/openproject_gitlab_integration`).
2. Set **GitLab instance URL** to your GitLab server, e.g. `https://gitlab.example.com`
   (no trailing path — just the host).
3. Save.

> Every branch‑creation request is sent to **this host only**. It's the single
> place the GitLab address is configured, which also keeps the server from being
> pointed at arbitrary hosts.

### 2. Project admin — link the GitLab project

The project must have the **GitLab** module enabled first: **Project settings →
Modules → GitLab**.

1. In the project, go to **Project settings → GitLab**.
2. Fill in:
   - **GitLab project ID or path** — either the numeric project ID (e.g. `42`)
     or the full path (e.g. `my-group/my-repo`). Both are shown on the GitLab
     project's home page.
   - **Default branch to create branches from** *(optional)* — leave blank to
     use the GitLab project's own default branch; set it (e.g. `develop`) to
     branch from somewhere else.
3. Save.

Requires the **Manage GitLab project settings** permission (project admins have
it by default).

### 3. Each user — add your GitLab token

Every user who wants to create branches configures their own token.

1. Open **My account → GitLab token** (top‑right avatar → *My account*; direct
   URL: `/my/gitlab_token`).
2. In GitLab, create a **Personal Access Token** with the **`api`** scope
   (GitLab → *Preferences → Access tokens*).
3. Paste it into **Personal access token** and save.

> **Scope matters:** use the **`api`** scope, **not** `write_repository`.
> `write_repository` only works for Git over HTTP (clone/push) and is rejected
> by the REST API that this feature uses. Your token is stored encrypted and is
> never shown back in the browser.

---

## Using it

1. Open any work package and select the **GitLab** tab.
2. Click **Git snippets** (the console icon) to open the *Quick snippets for Git*
   menu.
3. Click **Create branch in GitLab**.
4. A confirmation appears with the branch name (e.g. *"Branch created in GitLab:
   feature/1234-fix-login"*). If the branch already existed, you'll see
   *"Branch already exists in GitLab: …"* instead — no error, nothing is
   overwritten.

The branch now exists in GitLab, created under your GitLab identity.

---

## Verify end‑to‑end

Use this as an acceptance checklist. It assumes a test GitLab project you can
write to.

1. **Admin setting** — after step 1 above, reopen **Administration → Plugins**;
   the **GitLab instance URL** shows your host. ✅
2. **Project mapping** — after step 2, reopen **Project settings → GitLab**; your
   project ID/path is still there. ✅
3. **Token** — after step 3, reopen **My account → GitLab token**; it reads
   *"A token is currently stored"* (the value is never displayed). ✅
4. **Happy path** — on a work package's GitLab tab, click **Git snippets →
   Create branch in GitLab**. Expect the success toast with the branch name, and
   the branch to appear in GitLab (Repository → Branches), authored by you. ✅
5. **Idempotent** — click it again on the same work package. Expect *"Branch
   already exists in GitLab: …"* and **no** duplicate/error. ✅
6. **Naming** — confirm the created branch matches
   [the naming rule](#how-the-branch-is-named) for that work package. ✅
7. **Guard rails** (optional negative tests):
   - Remove your token, click the button → clear error asking you to configure a
     token (see [Troubleshooting](#troubleshooting)).
   - On a project with no GitLab mapping → clear error asking an admin to
     configure it.

---

## How the branch is named

The name is built from the work package and matches the **Branch name** snippet
in the same menu:

```
<type>/<id>-<subject>
```

- Lower‑cased; each part is sanitized (non‑alphanumeric runs become a single
  `-`; `&` becomes `and`; leading/trailing dashes trimmed).
- Example: a **User story** #1234 titled *"Fix login & signup!"* →
  `user-story/1234-fix-login-and-signup`.

---

## Troubleshooting

The button reports a readable message on failure. Common cases:

| Message | Cause | Fix |
|---|---|---|
| *This project is not linked to a GitLab project yet…* | No project mapping | Project admin completes [Setup step 2](#2-project-admin--link-the-gitlab-project) |
| *You have not configured a GitLab personal access token yet…* | No token for you | Complete [Setup step 3](#3-each-user--add-your-gitlab-token) |
| *No GitLab instance URL is configured…* | Admin setting missing | Admin completes [Setup step 1](#1-administrator--gitlab-instance-url) |
| *GitLab rejected the request… `api` scope* | Token invalid or wrong scope | Recreate the GitLab PAT with the **`api`** scope |
| *The configured GitLab project could not be found…* | Wrong project ID/path, or your token can't access it | Fix the mapping, or get access in GitLab |
| *Could not determine which branch to create from…* | No default branch resolvable | Set **Default branch** in the project's GitLab settings |
| *Could not reach GitLab…* | Network/host problem | Check the instance URL and connectivity |

---

## Notes & limitations

- **Single GitLab instance.** All projects point at the one admin‑configured
  host. Multiple GitLab servers are not supported in this version.
- **Start ref.** Branches are cut from the project's default branch unless a
  **Default branch** is set on the project's GitLab settings.
- **Permissions.** Anyone who can see the project's GitLab content can use the
  button; configuring the project mapping needs *Manage GitLab project settings*.
  The real write permission is enforced by GitLab against your token.
- **Security.** Your token is encrypted at rest and never sent back to the
  browser. Branches are attributed to you in GitLab because they're created with
  your token.
- **`api` scope breadth.** `api` grants broad API access — that's the narrowest
  standard PAT scope that can call the branch‑creation endpoint. If that breadth
  is a concern, use a dedicated GitLab bot/project access token instead of a
  personal one.
