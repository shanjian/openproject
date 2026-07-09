# Design: One-click "Create branch in GitLab"

> Status: Implemented on branch `feature/gitlab-create-branch` (off `epic`).
> Goal: On a work package's GitLab tab, in addition to the existing "copy
> branch name" snippet, add a "Create branch in GitLab" button that creates a
> branch named after the work package directly in the mapped GitLab project.

---

## 0. Key correction to the original premise (read first)

The original proposal assumed that "OpenProject already calls the GitLab API, so
we can just reuse the existing client." **That is not true in this codebase.**

`modules/gitlab_integration` is a **webhook receiver only**:

- GitLab pushes events to OpenProject
  ([hook_handler.rb](modules/gitlab_integration/lib/open_project/gitlab_integration/hook_handler.rb#L31-L48)),
  which merely receives them and `upsert_*`s local records
  ([services/](modules/gitlab_integration/lib/open_project/gitlab_integration/services/)).
- The module has **no outbound HTTP client**, no GitLab base URL, and no access
  token (grep for `Net::HTTP` / `Faraday` / `api/v4` / `private_token` returns
  nothing).
- The "copy branch name" front-end is a **pure client-side clipboard** action
  ([git-actions.service.ts:64](modules/gitlab_integration/frontend/module/git-actions/git-actions.service.ts#L64-L67),
  [git-actions-menu.component.ts:100](modules/gitlab_integration/frontend/module/git-actions-menu/git-actions-menu.component.ts#L100));
  it never touches the backend.

So this feature is really about **building the entire outbound half from
scratch**. The bulk of the work is credential storage, project mapping, and the
outbound client — the button itself is the easy part.

Good news: there is an established pattern for outbound calls — `OpenProject.httpx`
(with bearer/basic auth), as used by the GitHub integration in
[check_deploy_status_job.rb:160](modules/github_integration/app/workers/cron/check_deploy_status_job.rb#L160).

---

## 1. Decisions (all locked)

| Topic | Decision | Rationale |
|---|---|---|
| Write credential | **Per-user PAT** (requires the `api` scope) | Branches are created as the real user; cleanest GitLab-side audit & permissions |
| GitLab project mapping | **Configured explicitly in the OpenProject project settings** | Works even for a brand-new work package with no MR activity; configured once per project |
| Outbound client | Reuse `OpenProject.httpx` | Consistent with the GitHub integration |
| GitLab instance address | **Single global admin setting** (single-instance assumption) | Bounds the SSRF surface; the project level stores only the project ID/path |
| GitLab instance count | **Single instance** | Multi-instance would require a host allowlist; deferred |
| Branch start ref | **Default branch** | Project setting may pin a ref; blank → query the project's `default_branch` at runtime |
| Permission | **Reuse `show_gitlab_content`** for the create action | Real write permission is enforced by the GitLab PAT anyway |
| Error UX | **Include a docs link** | On an invalid/insufficient token, the error names the `api` scope and links the GitLab PAT docs |

---

## 2. Configuration, in three layers

### 2.1 Global (Admin → plugin settings)
- `gitlab_base_url`: the GitLab instance address, e.g. `https://gitlab.example.com`.
- Purpose: every outbound request may only ever target this host (**SSRF
  containment** — user/project config never supplies a host at call time).
- Storage: plugin settings, following the GitHub integration's use of
  `Setting.plugin_openproject_github_integration`
  ([check_deploy_status_job.rb:133](modules/github_integration/app/workers/cron/check_deploy_status_job.rb#L133)).
- **Implemented:** `Engine.settings` default + admin partial
  [`settings/_gitlab_integration.html.erb`](modules/gitlab_integration/app/views/settings/_gitlab_integration.html.erb).

> If multiple GitLab instances become necessary later: move the host to the
> project level, but a **global host allowlist** then becomes mandatory. Not in
> this iteration.

### 2.2 Per project (Project settings → GitLab)
- `gitlab_project_id`: the numeric GitLab project ID, or the URL-encoded
  `namespace/project` path (GitLab's API `:id` accepts both).
- `default_ref` (optional): the ref to branch from; blank → query the project's
  `default_branch` at runtime.
- Storage: table `gitlab_project_settings`, `belongs_to :project`
  ([model](modules/gitlab_integration/app/models/gitlab_project_settings.rb)).
- UI: a project-settings page guarded by the `manage_gitlab_settings`
  permission ([controller](modules/gitlab_integration/app/controllers/projects/settings/gitlab_controller.rb)).

### 2.3 Per user (My account → GitLab token)
- Each user enters their own GitLab PAT with the **`api`** scope.
  > Note: **not** `write_repository`. Per GitLab's token-scope docs,
  > `write_repository` only authenticates Git-over-HTTP, not the REST API. Branch
  > creation uses the REST Branches API (`POST /projects/:id/repository/branches`),
  > which requires the `api` scope.
- Storage: table `gitlab_user_tokens`
  ([model](modules/gitlab_integration/app/models/gitlab_user_token.rb)). A raw
  PAT (not an OAuth flow) fits a small dedicated table best.
- **Always encrypted at rest.** The token is a write-capable credential, so it
  is encrypted with `ActiveSupport::MessageEncryptor` (AES-256-GCM) using a key
  derived from the app's `secret_key_base`. This is deliberately **not**
  `Redmine::Ciphering` (used for repo/LDAP passwords), which silently falls back
  to plaintext when the optional `database_cipher_key` is unset (its default).
  `secret_key_base` is always present, so the PAT is never stored in the clear —
  and saving is never blocked on encryption configuration.
- The **PAT is never sent to the front-end**; it is only used server-side when
  making the outbound call.
- UI: a self-contained "My account" page
  ([controller](modules/gitlab_integration/app/controllers/gitlab_integration/my_gitlab_token_controller.rb)),
  mirroring the avatars module, to minimise coupling to the upstream
  access-tokens page.

---

## 3. Create-branch flow (end to end)

```
[front-end button] --POST--> [OpenProject endpoint] --httpx--> [GitLab API]
```

1. **Front-end**: a "Create branch in GitLab" button in the git-actions menu
   POSTs to the new endpoint (see §4) with the work package id, and shows a
   loading state.
2. **Backend `CreateBranchService`**:
   1. Load the work package → project → project mapping (§2.2). Not configured
      → 422 with a clear message.
   2. Load the current user's PAT (§2.3). Missing → 422 with a clear message.
   3. **Compute the branch name server-side** (do not trust the client). The
      sanitisation rules currently live only in TS
      ([git-actions.service.ts:38](modules/gitlab_integration/frontend/module/git-actions/git-actions.service.ts#L38-L46));
      they are reimplemented in Ruby and must stay in sync (format
      `type/id-title`).
   4. Resolve the ref: the project's `default_ref`, else `GET /projects/:id` →
      `default_branch`.
   5. `POST {base_url}/api/v4/projects/{id}/repository/branches` with query
      `branch=<name>&ref=<ref>` and header `PRIVATE-TOKEN: <pat>`, via
      `OpenProject.httpx`.
   6. Map the response:
      - `201` → success, return `web_url` / branch name.
      - `400 Branch already exists` → treated as an informational success.
      - `401/403` → invalid token or missing `api`.
      - `404` → wrong project mapping / token has no access.
   7. Return a `ServiceResult`.
3. **Front-end**: success → toast + link to the new branch; failure → the
   human-readable error from the backend.

---

## 4. Backend endpoint

An **API::V3 sub-resource** mounted under `WorkPackagesAPI` (matching the
module's existing `GitlabMergeRequestsByWorkPackageAPI` style):

```
POST /api/v3/work_packages/:id/gitlab/branches
```

- Endpoint: [gitlab_branches_by_work_package_api.rb](modules/gitlab_integration/lib/api/v3/gitlab_branches/gitlab_branches_by_work_package_api.rb),
  wired in [engine.rb](modules/gitlab_integration/lib/open_project/gitlab_integration/engine.rb) via `add_api_endpoint`.
- Authorised with `show_gitlab_content` (decision §1).
- Service in `app/services/gitlab_integration/` returning `ServiceResult`
  ([create_branch_service.rb](modules/gitlab_integration/app/services/gitlab_integration/create_branch_service.rb)).
- Outbound calls wrapped in `GitlabIntegration::APIClient`
  ([api_client.rb](modules/gitlab_integration/app/services/gitlab_integration/api_client.rb))
  around `OpenProject.httpx`, easy to stub in tests.

---

## 5. Files added / changed

**Added**
- `db/migrate/20260709100000_create_gitlab_project_settings.rb` + model `GitlabProjectSettings`
- `db/migrate/20260709100001_create_gitlab_user_tokens.rb` + model `GitlabUserToken` (ciphered token)
- `app/services/gitlab_integration/api_client.rb` — `GitlabIntegration::APIClient`
- `app/services/gitlab_integration/create_branch_service.rb` — `GitlabIntegration::CreateBranchService`
- `lib/api/v3/gitlab_branches/gitlab_branches_by_work_package_api.rb` — grape endpoint
- `app/controllers/projects/settings/gitlab_controller.rb` + view — project settings page
- `app/controllers/gitlab_integration/my_gitlab_token_controller.rb` + view — My account page
- `app/views/settings/_gitlab_integration.html.erb` — admin settings partial
- `config/routes.rb` — module routes (project settings + My account token)
- Specs: `spec/services/.../create_branch_service_spec.rb`, `spec/models/gitlab_user_token_spec.rb`

**Changed**
- `lib/open_project/gitlab_integration/engine.rb` — settings, permissions, menus, API endpoint
- `frontend/module/git-actions-menu/git-actions-menu.component.ts` + `.template.html` — the button + API call
- `config/locales/en.yml`, `config/locales/js-en.yml` — new strings

---

## 6. Permissions & security

- **OpenProject-side permissions**:
  - Create action: reuses `show_gitlab_content`
    ([engine.rb](modules/gitlab_integration/lib/open_project/gitlab_integration/engine.rb)).
  - Settings page: new `manage_gitlab_settings` (project members/admins).
- **Actual write permission is enforced by the GitLab PAT**: OpenProject only
  relays the request; anything unauthorised is rejected by GitLab (401/403).
- **SSRF**: the host comes only from the global admin setting (§2.1); no
  arbitrary URL is accepted at call time.
- **Credential protection**: the PAT is stored ciphered, never sent to the
  front-end, and not logged.
- **Audit**: branches are created with the user's PAT, so GitLab attributes them
  to the correct user.
- **Deletion**: both tables use `on_delete: :cascade` foreign keys, so deleting a
  project or user removes its GitLab mapping/token instead of raising a FK
  violation. Covered by model specs.

---

## 7. Maintenance cost (honest note)

This is an intrusive change on a fork. Each upstream upgrade may require
re-applying the patch, especially
[engine.rb](modules/gitlab_integration/lib/open_project/gitlab_integration/engine.rb)
and the front-end component. Mitigations:
- Keep new logic in new files to minimise edits to upstream files (engine.rb
  edits are unavoidable but kept small).
- Insert the front-end button additively rather than rewriting the menu.

---

## 8. Decisions (finalised — all pre-implementation questions resolved)

1. **Single instance.** One global GitLab base URL in the admin settings (§2.1);
   no arbitrary host at call time; minimal SSRF surface. Multi-instance deferred.
2. **Default branch as the start ref.** The project setting may pin a
   `default_ref`; blank → query the GitLab project's `default_branch` at runtime.
   No per-click ref picker.
3. **Docs link provided.** On an invalid token / missing `api`, the
   error message links the GitLab "Create a Personal Access Token" docs and names
   the required scope.
4. **Reuse `show_gitlab_content`** for the create action; no dedicated
   `create_gitlab_branch` permission. Real write permission is enforced by the
   GitLab PAT. The settings page uses the separate `manage_gitlab_settings`.

---

## 9. Verification status

- Specs pass: `create_branch_service_spec` (error mapping) and
  `gitlab_user_token_spec` (cipher round-trip, uniqueness).
- rubocop / erb_lint clean on new code; eslint introduces no net-new violations
  (the legacy component has pre-existing debt).
- Migrations run on the test DB; the app boots, routes resolve, the plugin
  registers, and the grape endpoint constant loads.
- **Not yet verified**: an end-to-end call against a live GitLab instance (needs
  a writable GitLab project + a PAT with `api`). The HTTP round-trip
  is only exercised via stubs in unit tests.
