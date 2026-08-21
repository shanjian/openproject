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
| Our `mcp` gem | `~> 0.24.0` (was `0.8.0`) |
| Upstream `mcp` gem | `~> 0.24.0` |

Our tree is not simply "at 17.1.2" for MCP. An earlier partial sync already brought in
`ServerUrlComponent`, the `mcp_tool_response_format` setting and `McpTools::Base::RESPONSE_FORMATS`
without their translations, which is what made the admin page return a 500 until that was fixed.
Expect more of this kind of half-applied state.

## Already applied

Listed so this doc reads as a complete picture.

On `feature/mcp-gem-0-24-upgrade`:

- **`mcp` gem `0.8.0` -> `0.24.0`** with upstream's `McpTools::Base` refactor. See
  [what the upgrade actually changed](#done-the-gem-upgrade-and-base-refactor) below.
- **`total` in paginated responses** (was item 3). `apply_pagination` returns
  `[scope, total]` and all six search tools report it.
- **`output_filter` hook** on `base.rb`, so item 1 below is a pure addition.

On `feature/ungate-mcp-server`:

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

## Done: the gem upgrade and base refactor

This was the blocker for everything below. It is done.

**One correction to what this doc previously claimed.** It said the gem "removes"
`output_schema`. It does not — mcp 0.24 still ships `MCP::Tool::OutputSchema` and
`MCP::Tool.define(..., output_schema:)`, and gem-side result validation exists as
`Configuration#validate_tool_call_results` (defaulting to `false`). Dropping
`output_schema` was upstream's *choice*, and we followed it deliberately: nothing was
connected to the server yet, so removing `outputSchema` from `tools/list` cost nothing,
and keeping per-tool schemas would have meant hand-writing one for every future ported
tool and would have conflicted with the output filters in item 1. If we ever want
validation back, `validate_tool_call_results` gives it to us at the right point —
after the output filters run.

The gem bump itself was close to transparent: `MCP::Server.new` and
`MCP::Tool::Response.new` are signature-compatible on every kwarg we pass. All the
churn was upstream's refactor:

- `output_schema` dropped from `base.rb` and from the six search tools that declared one,
  along with the dev-mode `validate_result` check and `validate_root_output_schema!`. The
  `resource_schema` shorthand that the three resource-proxy tools used went with it.
- `tool` became `tool(title:, description:)`; the `McpConfiguration` lookup moved out
  into `McpTools.enabled_mcp_tools` / `McpResources.enabled_mcp_resources`.
- `McpTools.all` / `McpResources.all` became mutable registries populated by `register`,
  replacing the hardcoded arrays.
- `format_structured_content` gained a `JSON.parse(result.to_json)` round-trip
  "because the mcp gem performs strict type checks on the structured content".
- `apply_pagination` returns `[scope, total]` and every search tool returns `total:`.

**Deliberate deviations from upstream**, all of them small:

- **Registration runs in `to_prepare`, not `after_initialize`.** `McpTools` lives under
  `app/services`, so Zeitwerk unloads it — and the registry with it — on every dev
  reload, while `after_initialize` never runs again. Upstream's version silently
  serves zero tools after the first file edit in development.
- **`register` is idempotent**, because `to_prepare` fires more than once per reload
  cycle. Upstream's unconditional `all << t` duplicates every entry on the first reload
  (verified: 9 tools become 18), which would double every row on the admin page and make
  the seeder visit each tool twice. `register` now unions into the registry and drops the
  memoized `tools_by_name` / `resources_by_name` lookup. Covered by
  `spec/services/mcp_tools_spec.rb` and `spec/services/mcp_resources_spec.rb`, both of
  which fail against upstream's version.
- The `search_projects`, `search_portfolios`, `search_programs` and `search_versions`
  descriptions keep our missing-space fix; upstream still renders "with apage number" in
  all four.
- **`format_structured_content` does not round-trip again.** `format_response` has already
  converted the representers into plain hashes by the time it is called, so upstream's
  `JSON.parse(result.to_json)` there can only ever be a no-op on an already-converted
  hash. Ours returns the hash as-is. Response bodies are byte-identical either way; the
  505 request specs assert them deeply and pass unchanged.
- `filter_class` stays a String, as does the doc example in `base.rb`.
- Not taken from upstream's `base.rb` consumers: the `output_filter` *declarations* on
  `search_work_packages` (item 1), the custom-field sentence in its description
  (item 2), and `target_version_id` (item 5).

### Where the time actually goes

Measured on a 40-work-package search response (202 KB of JSON), warm:

| | |
|---|---|
| Building + serializing the page (representers) | ~334 ms |
| Redundant `format_structured_content` round-trip, now removed | 2.58 ms |
| The `COUNT(*)` that `total` added | 1.29 ms |

**Almost all of it is representer materialization**, not JSON handling or querying. Two
consequences:

- The round-trip in `format_response` is *necessary*, not waste — it is what converts the
  representers into the plain hashes the gem type-checks, needed with or without output
  filters. Only the second one, in `format_structured_content`, was redundant.
- This bounds item 1. Output filters run *after* the representers are built, so they cut
  the tokens a model pays for but will not make a search call faster. If search latency
  ever becomes the complaint, the fix is narrowing what the representer renders, not
  filtering its output.

## Outstanding items

### 1. Output filters — best value for effort

`app/services/mcp_output_filters/`: `HashFilter` base plus `RemoveFormattableHtml`
(drops the `html` twin of every `{format, raw, html}` triple), `RemoveLinks`,
`RemoveWorkPackageActionLinks` (strips 23 HAL action links: `update`, `delete`, `logTime`,
`watch`, `addRelation`, …) and `RemoveActivityDetails`.

- **Gain:** large and immediate, but in tokens only. Work package payloads currently ship
  rendered HTML alongside the raw markdown and a wall of action links the model cannot
  use, on every single call. Measured above: filters run after the representers are built,
  so they will not reduce response latency.
- **Risk:** low now. The `output_filter` / `output_filters` hook is already on `base.rb`
  and `format_response` already runs the filters, so this is purely adding the four
  filter classes plus the two `output_filter` declarations on `search_work_packages`.
  The reason this used to be medium-risk — the filters strip keys our `output_schema`
  declarations validated against — no longer applies; those declarations are gone.
- **Verdict:** highest-value item and now the cheapest. Do it next.

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
- **Risk:** low. They are written against the post-upgrade base (no `output_schema`,
  `apply_pagination` returning `total`, `output_filter`), which is now what we have, so
  they are close to drop-in. The remaining work is the `search_work_packages`
  description sentence telling the model to resolve custom field names through these
  tools, which we deliberately held back until the tools exist.
- **Verdict:** take after item 1, custom fields first.

### 3. `total` in paginated responses — DONE

Landed with the gem upgrade; `apply_pagination` returns a count and all six search tools
report `total:`. Costs one extra `COUNT` query per search call.

Worth knowing: neither we nor upstream mention `total` in any tool description, and with
`output_schema` gone there is no declared output shape either. A model discovers it only
by reading the response body. If paging in practice turns out to be worse than the
mechanism allows, adding a sentence to the search descriptions is the cheap fix.

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

Item numbers are stable — `docs/features/MCP_FEATURE_GUIDE.md` cites items 1 and 2 by
number, so renumber nothing.

1. ~~Gem upgrade + base refactor~~ — done.
2. ~~`total`~~ (item 3) — done, came with the refactor.
3. **Output filters** (item 1). Biggest token win, and now the cheapest change in the
   list: the hook is already in place.
4. **Read-only tools** (item 2), custom fields first. Near drop-in on the new base. Also
   unblocks the custom-field sentence held back from the `search_work_packages`
   description.
5. **Write tools** (item 4) — separate branch, separate review, after the open questions
   there are answered.
6. Leave item 5 to the Release/Sprint work and item 6 to natural upstream drift.

Items 1-3 are read-only and sit behind the per-tool admin toggles, so each can ship and
be reverted independently. Item 4 is the write tools and needs its own review before any
of it ships.

When items 1 and 2 land, `MCP_FEATURE_GUIDE.md` needs updating with them: the
"Responses are verbose" note and the `customFieldN` troubleshooting entry both describe
gaps those items close.
