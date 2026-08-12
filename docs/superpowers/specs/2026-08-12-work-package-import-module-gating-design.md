# Gate the Markdown work package import behind its own project module

**Date:** 2026-08-12
**Status:** Approved

## Problem

The "Import work packages from Markdown" entry point appears as a top-level item in the
project sidebar of *every* project. Two distinct defects:

1. **Availability.** The menu item (`config/initializers/menus.rb:719`) is gated on
   `project.module_enabled?("work_package_tracking")` plus the `import_work_packages`
   permission. The permission is registered inside the `work_package_tracking` project
   module (`config/initializers/permissions.rb:332`), and that module is enabled in
   essentially every project. Admins hold every permission, so the item is visible
   everywhere. Only a small set of projects (the OKR projects) need the importer.

2. **Placement.** It occupies a permanent top-level sidebar slot with no icon and a
   caption too long to fit ("Import work packages from Mar…"), for an action used
   periodically rather than daily.

## Key mechanism

`allowed_in_project?` already filters the requested permissions by the project's enabled
modules, in `Authorization::UserPermissibleService#allowed_in_single_project?`
(`app/services/authorization/user_permissible_service.rb:106-115`):

```ruby
permissions_filtered_for_project = permissions_by_enabled_project_modules(project, permissions)
return false if permissions_filtered_for_project.empty?
```

This runs *before* the admin short-circuit inside `cached_permissions`, so a permission
whose owning module is disabled returns `false` even for an admin. Therefore moving
`import_work_packages` into its own module is sufficient to gate both the menu item and
the controller — no new module checks are needed anywhere.

## Design

### 1. New project module

Lift `import_work_packages` out of the `work_package_tracking` block in
`config/initializers/permissions.rb` into its own module:

```ruby
map.project_module :work_package_import,
                   dependencies: :work_package_tracking,
                   order: 95 do |wpi|
  wpi.permission :import_work_packages,
                 { "work_packages/imports": %i[new preview create show] },
                 permissible_on: :project,
                 dependencies: %i[view_work_packages add_work_packages
                                  manage_subtasks assign_versions]
end
```

Decisions and their consequences:

- **The permission keeps its name.** `role_permissions` rows store permissions by name, so
  existing role assignments survive. **No data migration.**
- **Permission `dependencies:` stay as-is.** Those four names live in
  `work_package_tracking`. Cross-module permission dependencies are fine — the list only
  drives auto-checking in the role form, it is not resolved against module membership.
- **Module identifier is `work_package_import`, not `markdown_import`,** so a future CSV or
  per-project Jira importer can share the same per-project toggle.
- **`order: 95`** places it between `work_package_tracking` (90) and the `nil` module (100)
  in the role-permission form.
- **Not added to `default_projects_modules`.** A newly registered module has no
  `enabled_modules` rows, so it is off in every existing project and every newly created
  project until explicitly enabled via Project settings → Modules.
- **`dependencies: :work_package_tracking` needs no new code.**
  `Projects::EnabledModulesContract#validate_dependencies_met`
  (`app/contracts/projects/enabled_modules_contract.rb:46-56`) already rejects enabling a
  module whose dependency is off, with the `:dependency_missing` message.

New keys in `config/locales/en.yml`:

- `project_module_work_package_import` — the module's label in the Modules settings form
  and in the dependency validation message.
- `permission_header_for_project_module_work_package_import` — the section header in the
  role-permission form.

### 2. Menu relocation

`config/initializers/menus.rb:719` becomes:

```ruby
menu.push :work_packages_import,
          { controller: "/work_packages/imports", action: "new" },
          parent: :work_packages,
          first: true,
          caption: :"work_packages.import.menu_title",
          if: ->(project) { User.current.allowed_in_project?(:import_work_packages, project) }
```

- `parent: :work_packages, first: true` renders it above the saved-views list, since
  `work_packages_query_select` is pushed with `last: true`.
- The explicit `module_enabled?("work_package_tracking")` check is **dropped as redundant** —
  per "Key mechanism", `allowed_in_project?` now covers both the module and the permission.
- New short caption key `work_packages.import.menu_title: "Import from Markdown"`. The
  existing long `work_packages.import.new.title` stays as the page heading.

**Known risk.** The Work packages submenu carries custom query-menu styling and an Angular
`wp-query-menu` hook (`html: { "wp-query-menu": "wp-query-menu" }` on the parent). A plain
link as its first child is expected to render correctly, but must be confirmed in the
browser. If it cannot be made to look right, the fallback is a tidied top-level entry
(short caption plus an `upload` icon) — acceptable because the module gate already removes
it from non-OKR projects.

### 3. Tests

- `spec/features/work_packages/import_spec.rb` — project factories must include the new
  module in `enabled_module_names`; the menu navigation path changes to the Work packages
  submenu.
- `spec/controllers/work_packages/imports_controller_spec.rb` — same module enabling, plus
  a new case asserting the controller **rejects a project without the module**. This is the
  security-relevant assertion: the module now guards the endpoint, not merely the menu.
- A menu spec asserting the item is absent for an admin in a project without the module and
  present once the module is enabled.

## Out of scope

- Enabling the module on the OKR projects. That is a per-project checkbox the user ticks in
  Project settings → Modules; no seed data or migration will do it.
- Any change to the importer's parsing, preview, or creation behaviour.
- Adding an "Import" entry to the Angular work package table settings dropdown. Considered
  and rejected for this change: better UX, but it means editing legacy Angular that is being
  migrated away from, and plumbing module state into the frontend.
