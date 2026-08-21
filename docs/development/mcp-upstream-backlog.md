# MCP: upstream backlog for this fork

Survey of what upstream has done to the MCP server since our fork point, split into
what has already been pulled in and what is still outstanding. The outstanding items
are the high-gain / higher-risk ones that need a deliberate decision.

Companion to [upstream-sync-plan.md](upstream-sync-plan.md), which covers the general
`17.1.2 -> 17.7.1` catch-up and does not mention MCP.

## Reference points

| | |
|---|---|
| Fork point | `v17.1.2` (MCP first shipped upstream in `v17.1.0`) |
| Upstream surveyed | `upstream/dev` @ `4a95621961c`, 2026-08-21 |
| Latest upstream tag | `v17.7.2`; `release/17.8` branch open |
| Our `mcp` gem | `0.8.0` |
| Upstream `mcp` gem | `~> 0.24.0` |

Our tree is not simply "at 17.1.2" for MCP. An earlier partial sync already brought in
`ServerUrlComponent`, the `mcp_tool_response_format` setting and `McpTools::Base::RESPONSE_FORMATS`
without their translations, which is what made the admin page return a 500 until that was fixed.
Expect more of this kind of half-applied state.

## Already applied

Done on `feature/ungate-mcp-server`; listed so this doc reads as a complete picture.

- **Enterprise gating removed** from the endpoint, the admin page and the menu badge.
  The specs now assert MCP responds *without* a token, so a future merge that restores
  the gate fails the suite instead of silently re-gating us.
- **Missing translations** added from `upstream/release/17.7`
  (`server_form.tool_response_format*`, `server_url_component.*`, `oauth.scopes.mcp*`).
- **`filter_class` passed as a String and `constantize`d** at call time instead of
  referencing `Queries::...` constants in class bodies. Autoload robustness; no behaviour change.
- **Deterministic ordering** of tool/resource rows on the admin page (`.order(identifier: :asc)`).
- **Exception reporter** now logs a backtrace line when the exception has no `cause`.
- **Missing space** in the `search_work_packages` description that produced "with apage number"
  in text an LLM reads.
- **Docs** refreshed from upstream; the stale "experimental, enable under
  `/admin/settings/experimental`" block is gone and the Enterprise badge is replaced by a
  note about our ungating.

## The blocker: `mcp` gem 0.8.0 -> 0.24.0

Nearly everything outstanding sits behind this. Upstream's refactor of
`McpTools::Base` is driven by the gem upgrade, not by taste:

- `output_schema` is **removed** from tools entirely, along with the dev-mode
  `validate_result` check and `resource_schema` on `ResourceProxyTool`.
- `tool` becomes `tool(title:, description:)`; the `McpConfiguration` lookup moves out
  into `McpTools.enabled_mcp_tools` / `McpResources.enabled_mcp_resources`.
- `McpTools.all` / `McpResources.all` become mutable registries populated by
  `register` from an `after_initialize` block, replacing the hardcoded arrays.
- `format_structured_content` gains a `JSON.parse(result.to_json)` round-trip
  "because the mcp gem performs strict type checks on the structured content".
- `apply_pagination` returns `[scope, total]` and every tool returns `total:`.

These are interlocked: `base.rb` cannot be taken without every tool file changing in
lockstep. Our 497 MCP specs currently pass on 0.8.0, including the dev-mode
`validate_result` path (`Rails.env.local?` is true in test), so there is no bug forcing
our hand — this is a deliberate upgrade, not a fix.

**Estimated shape:** one focused branch, ~15 app files plus specs, no data migration.
Do this first; it unlocks everything below.

## Outstanding items

### 1. Output filters — best value for effort

`app/services/mcp_output_filters/`: `HashFilter` base plus `RemoveFormattableHtml`
(drops the `html` twin of every `{format, raw, html}` triple), `RemoveLinks`,
`RemoveWorkPackageActionLinks` (strips 23 HAL action links: `update`, `delete`, `logTime`,
`watch`, `addRelation`, …) and `RemoveActivityDetails`.

- **Gain:** large and immediate. Work package payloads currently ship rendered HTML
  alongside the raw markdown and a wall of action links the model cannot use. This is
  pure token cost on every single call.
- **Risk:** medium. Needs the small `output_filter` / `output_filters` addition to
  `base.rb` (~8 lines, independent of the gem), but it strips keys that our still-present
  `output_schema` declarations validate against in dev and test. Either take it with the
  gem upgrade above, or verify the JSON schemas tolerate the removals first.
- **Verdict:** highest-value item. Worth considering ahead of the full gem upgrade if
  the schema interaction turns out to be benign.

### 2. Read-only tools we are missing

Four tools and one resource, all `read_only: true, destructive: false`:

| Tool | Notes |
|---|---|
| `list_work_package_comments` | journals/comments for a WP |
| `list_work_package_relations` | relations for a WP |
| `search_custom_fields` | resolves `customFieldN` to real names |
| `search_custom_field_items` | hierarchy custom field items |
| `McpResources::CustomField` | matching resource |

- **Gain:** solid. The custom field pair matters more for us than for upstream — this
  fork leans on custom fields heavily (the "End Date" field behind the done-date
  feature, for one), and without these an agent reports raw `customField7` labels.
  Upstream's own `search_work_packages` description now instructs the model to resolve
  names through these tools rather than showing `customFieldN`.
- **Risk:** medium, and entirely from porting. They are written against the post-upgrade
  base (no `output_schema`, `apply_pagination` returning `total`, `output_filter`), so
  they are not drop-in on our tree.
- **Verdict:** take with or right after the gem upgrade.

### 3. `total` in paginated responses

`apply_pagination` returns a count and every search tool returns `total:`.

- **Gain:** moderate but real. Pagination is currently blind — the tool description tells
  the model to "call again with a page number of 2 or higher" with no way to know whether
  there is a page 2. Models either stop early or page pointlessly.
- **Risk:** low in isolation, and independent of the gem. Touches `base.rb` plus all six
  search tools, and adds a `total` key that the `output_schema` declarations do not list.
- **Verdict:** the one substantial item that could be done standalone if the gem upgrade
  gets deferred. Costs one extra `COUNT` query per search call.

### 4. Write tools — high gain, high risk

Six tools, all going through the normal service objects with `user: current_user`, so
contracts and permissions are enforced the same way the API v3 enforces them:

| Tool | Annotations | Service |
|---|---|---|
| `create_work_package` | not read-only, not idempotent | `WorkPackages::CreateService` |
| `update_work_package` | not read-only, idempotent | `WorkPackages::UpdateService` |
| `create_work_package_comment` | not read-only, not idempotent | `AddWorkPackageNoteService` (`send_notifications: true`) |
| `create_work_package_relation` | not read-only, not idempotent | `Relations::CreateService` |
| `update_work_package_relation` | not read-only, idempotent | `Relations::UpdateService` |
| `delete_work_package_relation` | not read-only, **destructive** | `Relations::DeleteService` |

- **Gain:** this is the qualitative jump. It turns MCP from a reporting window into
  something an agent can act through.
- **Risk:** high, and not mainly technical. The service-object routing means authorization
  is sound and an agent can do nothing the same user could not do through the UI. The real
  exposure is that an LLM now writes to live project data on behalf of whoever's token it
  holds, `create_work_package_comment` notifies subscribers on every call, and
  `delete_work_package_relation` is genuinely destructive. Our `McpConfiguration` per-tool
  toggles are the natural control — they let each write tool be enabled individually.
- **Open questions for the review:**
  - Enable per tool, or all-or-nothing? Per-tool is already supported.
  - Comments notify by default. Do we want agent-authored comments hitting subscribers?
  - Do we want an audit trail distinguishing agent-authored changes from human ones?
    Journals will attribute them to the token's user with nothing marking them as agent work.
  - Should write tools be restricted to specific projects or roles?
- **Verdict:** defer until reviewed. Note upstream's own docs still say MCP is read-only,
  so this is fresh and unreleased work — worth letting it settle upstream regardless.

### 5. Version filtering — do not take as-is

`search_work_packages` gains `target_version_id` and reworks `version_id` into a
deprecated alias, both filtering the `target_versions` association because
`work_packages.version_id` is being retired. Upstream's `work_package_multiple_versions`
feature flag ("Enables assigning multiple (target) versions to a work package") is the
other half of this.

- **Risk:** high, and specific to us. Our tree has no `with_target_version` /
  `without_target_version` scopes, and `version_id` carries fork-specific meaning in the
  Release/Sprint model. Porting the MCP half alone would break the filter; porting the
  whole thing collides with our version semantics head-on.
- **Verdict:** blocked on the Release/Sprint work, not an MCP decision. Flagging it here
  because it is the first place upstream's multi-version migration reaches into code we
  have already diverged on, and it will not be the last.

### 6. Minor, blocked on other upstream work

- `McpResources::WorkPackage` moves from `find_by(id:)` to `find_by_display_id(id)`.
  We have no `find_by_display_id`; it arrives with unrelated upstream work.
- `McpResources::User` drops a `Rails/DynamicFindBy` rubocop disable, which depends on
  their newer rubocop config.
- Upstream re-exported the three MCP screenshots at smaller file sizes. Pure churn; ours
  are still accurate.

## Suggested order

1. **Gem upgrade + base refactor** (the blocker above). Unlocks the rest, no data migration.
2. **Output filters** (item 1). Biggest token win, lands cleanly on the new base.
3. **Read-only tools** (item 2), custom fields first.
4. **`total`** (item 3) — comes almost free with the refactor.
5. **Write tools** (item 4) — separate branch, separate review, after the questions above
   are answered.
6. Leave item 5 to the Release/Sprint work and item 6 to natural upstream drift.

Items 1-3 are read-only and sit behind the per-tool admin toggles, so each can ship and
be reverted independently. Item 4 is the write tools and needs its own review before any
of it ships.
