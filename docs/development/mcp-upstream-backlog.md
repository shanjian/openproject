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

On `feature/mcp-wp-detail-tools`:

- **The rest of item 2**: `list_work_package_comments` and
  `list_work_package_relations`, plus `RemoveActivityDetails` deferred from item 1.
  Item 2 is now complete.

On `feature/mcp-custom-field-tools`:

- **The custom field half of item 2**: `search_custom_fields`, `search_custom_field_items`
  and `McpResources::CustomField`, plus the `search_work_packages` description sentence
  held back in #147. An agent can now resolve `customField7` to a real name.

On `feature/mcp-output-filters`:

- **Output filters** (was item 1). `HashFilter`, `RemoveFormattableHtml`, `RemoveLinks` and
  `RemoveWorkPackageActionLinks`, declared on `search_work_packages`. Measured at **41.7%
  smaller** responses on a 10-work-package payload (50,589 -> 29,471 bytes).

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
- This bounded item 1, and the outcome matched: the filters cut responses by 41.7% but
  left latency untouched, because they run *after* the representers are built. If search latency
  ever becomes the complaint, the fix is narrowing what the representer renders, not
  filtering its output.

## Outstanding items

### 1. Output filters — DONE

`app/services/mcp_output_filters/`: `HashFilter` base plus `RemoveFormattableHtml` (drops
the `html` twin of every `{format, raw, html}` triple), `RemoveLinks` and
`RemoveWorkPackageActionLinks` (strips 22 HAL action links: `update`, `delete`, `logTime`,
`watch`, `addRelation`, …), declared on `search_work_packages`.

**Gain, measured:** a 10-work-package response drops from 50,589 to 29,471 bytes — 41.7%
smaller — with 192 blocked action links and 10 rendered-HTML twins removed. Tokens only:
the filters run after the representers are built, so response latency is unchanged.

**Not taken:** `RemoveActivityDetails`, whose only caller is `list_work_package_comments`
in item 2. It arrives with that tool, where its behaviour can be tested against a real
payload instead of a synthetic one.

**Two adaptations, both spec-pinned so a future sync cannot quietly revert them:**

- `HashFilter#on_hash` raised `SubclassResponsibilityError`, which **does not exist
  anywhere in our tree** — it arrived upstream with unrelated work, so upstream's file
  would `NameError` on the abstract path. Now `NotImplementedError, "subclass
  responsibility"`, this repo's dominant convention.
- **`HashFilter#filter` now returns the structure it was given.** Upstream returns the
  value of its `case` expression, which is `nil` whenever `#on_hash` stops the descent at
  the top level. Since `McpTools::Base#format_response` threads that return value through
  its filter chain, a tool whose result is a HAL document with top-level `_links` would
  have its **entire response body replaced by `nil`**. Upstream is only latently exposed
  (`list_work_package_comments` returns `{items:, total:}`), but all three of our
  `ResourceProxyTool` subclasses return exactly that shape, so adding `RemoveLinks` to one
  of them — a natural next step — would have broken it silently.

Worth knowing for item 2 and beyond: `RemoveLinks#on_hash` deliberately stops descending
once it finds `_links`, so `_embedded` children are never visited. That looks like a bug
and is not: all 22 blocked links live in a work package's own top-level `_links`, and
embedded projects, types and users do not carry them. Verified, not assumed.

Note also that filtering covers the **tool** path only. `McpResources.read_resource` does
not run output filters, so reading a work package as a resource still returns the full
payload.

### 2. Read-only tools we are missing — DONE

| Tool | Notes | Status |
|---|---|---|
| `search_custom_fields` | resolves `customFieldN` to real names | done |
| `search_custom_field_items` | hierarchy custom field items | done |
| `McpResources::CustomField` | matching resource | done |
| `list_work_package_comments` | journals/comments for a WP | done |
| `list_work_package_relations` | relations for a WP | done |

**Correction to what this doc claimed.** It said these were "close to drop-in" because
they target the post-upgrade base. That was wrong, and wrong for an avoidable reason: the
claim was made by reading the tool files without checking what they *call*. The tool files
themselves did port cleanly; their dependencies did not. Porting the three custom field
pieces needed:

- **`API::V3::CustomFields::CustomFieldRepresenter`** — absent here. 56 lines; all four of
  its dependencies were present, so it ported as-is with upstream's spec.
- **`docs/api/apiv3/components/schemas/custom_field_model.yml`** — absent, while
  `custom_field_properties.yml` and `custom_field_linked_properties.yml` were already
  here. Another half-applied sync of exactly the kind noted at the top of this doc.
- **`CustomFields::Hierarchy::HierarchicalItemAggregator`** — absent. Upstream extracted
  it from `ItemsAPI#flatten_tree_hash` so the MCP tool could reuse it; we took the
  extraction, so `items_api.rb` is now byte-identical to upstream instead of carrying an
  inline copy.
- **`HierarchicalItemService#hashed_subtree`** needed upstream's `depth: -1` default. The
  MCP tool omits `depth:`; ours required it, so every call raised
  `missing keyword: :depth`. Backward compatible — both existing callers pass it.
- **The APIv3 custom field show endpoint** — absent. `CustomFieldRepresenter`'s `self_link`
  advertises `/api/v3/custom_fields/{id}`, and upstream mounts a one-line
  `Endpoints::Show` for it that we did not have, so every custom field the MCP tools
  returned pointed at a 404. Mounting it makes `custom_fields_api.rb` identical to
  upstream. Upstream also ships `paths/custom_field.yml` but never referenced it from
  `openapi-spec.yml`; ours is wired in, so the documentation is actually published.
- **The `fieldFormat` enum needed `department` and `calculated_value`.** Upstream's schema
  lists neither, but both are registered here — `department` is a Community-available
  fork feature and `calculated_value` is Enterprise-gated. Since `search_custom_fields`
  returns every visible field, a valid response could violate our own documented schema.
  Note `empty` is registered too and deliberately stays out: it is an internal fallback
  formatter with a nil label, explicitly not selectable as a custom field's format.
- **`HierarchyItemRepresenter`'s parent link needed `.compact`**, and
  `hierarchy_item_read_model.yml` needed `depth` widened to `["integer", "null"]`. Both
  were live bugs in our tree, not new: a root hierarchy item has no label, so children
  linking to it emitted `title: null`, and our representer has always mapped
  `depth < 0` to `nil` while our schema forbade it. Nothing exercised that path before.

**What did *not* need changing, though it first looked like it did.** Upstream added an
admin short-circuit to `CustomFields::Scopes::Visible` (`all` if `active_admin?`), and
without it the ported specs returned zero rows. Porting it would have altered shared
custom field *visibility* semantics for the whole application. It turned out to be
unnecessary: our `on_visible_type_and_project` path already shows an admin every custom
field once any project with a type exists, and shows ordinary users only the fields on
projects they can see. Upstream's spec fixtures simply create bare custom fields on an
instance with no projects at all — a state no real instance is in. The fixtures were
adapted instead; the visibility scope was left alone.

**Enterprise caveat on `search_custom_field_items`.** Hierarchy custom fields are gated
behind `custom_field_hierarchies`, a *different* Enterprise feature from `mcp_server`, and
this fork has not ungated it. `CustomFieldsController` blocks creating one without a
token, so on a Community instance the tool has nothing to return. It is shipped and
correct, but inert until hierarchies are available. Ungating that feature is its own
decision, not an MCP one.

**The work package detail half went cleanly**, unlike the custom field half — and the
difference was doing the dependency sweep first. Everything both tools call already
existed: `Relation.visible`, `work_package.relations`, all five journal associations
`includes` names (`:bcf_comment` and `:storable_journals` included),
`RelationCollectionRepresenter.to_eager_load`, both docs schemas, both shared examples,
and the `relates_relation` / `follows_relation` / `emoji_reaction` factories.

One gap, and the earlier recommendation in this doc was **wrong**. It said to drop
`embed_emoji_reactions: true`, a kwarg upstream added to `ActivityRepresenter` for this
tool, on the grounds that an LLM has no use for reaction counts and a shared representer
should stay untouched. Porting it turned out to be the better call: the change is purely
additive and backward compatible — a new kwarg defaulting to `false`, so no existing
caller's behaviour moves — and it makes `activity_representer.rb` identical to upstream
while letting the tool and its spec port verbatim. Dropping it would have meant deleting
an upstream spec example and carrying divergence in three files instead of converging one.
If reaction noise ever matters, an output filter is the right layer for it. Verified
backward compatible against the 179 examples that cover the representer.

Also worth knowing: `internal_visible` degrades to `where(internal: false)` without the
`internal_comments` Enterprise feature, so `list_work_package_comments` returns ordinary
comments and is fully useful on Community — unlike `search_custom_field_items`. It reads
`User.current` rather than the user it is passed; in the MCP path those are the same
object, but that is a trap if it ever changes.

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
3. ~~Output filters~~ (item 1) — done. 41.7% smaller work package responses.
4. ~~Read-only tools, custom fields~~ (item 2) — done, along with the held-back
   `search_work_packages` description sentence.
5. ~~Read-only tools, work package detail~~ (rest of item 2) — done, with
   `RemoveActivityDetails` from item 1. **Everything read-only in this backlog is now
   ported.** What remains is item 4 (write tools), item 5 (blocked) and item 6 (drift).
6. **Write tools** (item 4) — separate branch, separate review, after the open questions
   there are answered.
7. Leave item 5 to the Release/Sprint work and item 6 to natural upstream drift.

Items 1-3 are read-only and sit behind the per-tool admin toggles, so each can ship and
be reverted independently. Item 4 is the write tools and needs its own review before any
of it ships.

A lesson worth keeping from items 1 and 2: **check what a ported file calls, not just the
file.** Twice the risk assessment written from reading tool files alone turned out
optimistic, and both times the real work was in their dependencies. Doing the sweep up
front on the work package detail tools took one pass and turned up nothing — which is
what a clean port looks like, and is the cheapest possible way to find out.
