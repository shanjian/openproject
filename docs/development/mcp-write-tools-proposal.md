# MCP: proposal to create, edit and comment on work packages

**Status:** phase 1 built in the working tree (uncommitted, not deployed). **Date:** 2026-10-13.
**Reopens:** item 4 of [mcp-upstream-backlog.md](mcp-upstream-backlog.md), for three of its six tools.

**Decided 2026-10-13:** reverse the August verdict; comments are in scope; the tools are **live by
default** (there is one production instance, and its owner is managing the rollout); start phase 1,
which includes the comment label (decision 11) and the allowlist (decision 12). See
[Live by default](#live-by-default-with-an-off-switch).

## Request

Let an MCP client create and edit work packages, and add comments to them. Today
[MCP_FEATURE_GUIDE.md](../features/MCP_FEATURE_GUIDE.md) says the server "cannot write", and the
code agrees: all thirteen registered tools are read-only.

## Recommendation

Add three tools: `create_work_package`, `update_work_package` and `create_work_package_comment`.
Nothing else writes. Mark the journal each call writes for the work package it targets, so a person reading the
activity can tell an assistant made the change (side-effect journals are covered under
[Agent marker](#agent-marker-on-journals)). Make each tool separately switchable by an
administrator.

The August review declined for two reasons, comment notifications and the missing audit trail.
Both are addressed below, and the third precondition ("a concrete use") is now met. The port is
small because every service already exists.

## Why reopen now

The backlog listed what would have to change. Checked against today:

| August reason or condition | Today |
|---|---|
| "Upstream's own documentation still describes MCP as read-only, so this is unreleased work." | **No longer true.** Upstream shipped create/update work package and create comment in **17.8.0 (2026-09-02)**; 17.9.0 added time entries. Current release is 17.9.1. |
| "Nothing currently needs an agent to write. Revisit when there is a concrete use." | There is one: this request. |
| Agent comments would notify every subscriber. | **Still true, and now accepted.** A comment notifies the people the UI would notify. The model cannot turn that off, and the comment tool has its own toggle. See [Notifications](#notifications). |
| Journals attribute agent edits to the token's user with nothing marking them as an agent's. | **Fixable**: journal `cause`, plus two small rules in journal creation so the marker survives. See [Agent marker](#agent-marker-on-journals). |
| Port dependency: `ParsingStruct` is nested in `ParseParamsService` here. | **Gone.** Upstream's 2026-08-24 commit `89ee7292d4` switched the tools to `ParseParamsService`, which already exists in our tree and keeps `ParsingStruct` nested. No extraction needed. |

Upstream moved after our survey (`4a95621961c`, 2026-08-21). On 2026-08-26 it refactored
`McpTools::Base` (Dry::Monads `Success`/`Failure`, filtering and pagination moved to a new
`SearchTool`). **We should not take that refactor.** Port the tools against our `Base`.

## Scope

**In:** `create_work_package`, `update_work_package`, `create_work_package_comment`, and one small
supporting read tool, `list_priorities` (see
[Discoverability](#discoverability-the-assistant-can-only-set-what-it-can-find)).

**Out, deliberately:**

- Editing or deleting comments.
- Relations (upstream has create/update/delete tools; still declined, not requested).
- Deleting work packages or anything else.
- Time entries.
- **Attachments and file links.** Out of scope *and blocked*, not merely unlisted: `data` accepts
  `_links.attachments` and `_links.fileLinks`, both with replacement semantics. Measured:
  `_links.attachments: []` on update **deleted the work package's existing attachment rows**. The
  contract does stop an assistant attaching another work package's attachment ("Attachments cannot
  be changed"), but it will attach the user's own unclaimed uploads. See
  [What `data` may contain](#what-data-may-contain).
- **Watchers.** `data` cannot manage them: the payload parser produced no watcher key from a
  `_links.watchers` entry (measured). What is *not* out of scope is a side effect of creating: the
  creating user is subscribed as a watcher of the new work package, silently and without a
  notification (`CreateService#set_user_as_watcher`), exactly as in the UI. That stays.
- Upstream's `find_by_display_id` and semantic IDs (backlog item 6): our tools look up by numeric ID.

## Design

### The tools

Keep upstream's names and input shapes so prompts and clients written for upstream work
unchanged, and so a later sync is a no-op diff.

| Tool | Input | Service | Annotations |
|---|---|---|---|
| `create_work_package` | `data` (APIv3 payload, required) | `WorkPackages::CreateService` | not read-only, not idempotent, not destructive |
| `update_work_package` | `id`, `data` incl. required `lockVersion` | `WorkPackages::UpdateService` | not read-only, idempotent, **destructive hint on** |
| `create_work_package_comment` | `work_package_id`, `comment`, optional `internal` | `AddWorkPackageNoteService` | not read-only, not idempotent, not destructive |

**Idempotent, for `update_work_package`, means:** repeating the call leaves the same final state
and writes no new journal. A verbatim repeat is in fact rejected, because the first call advanced
`lockVersion`; a repeat with a refreshed `lockVersion` and no further change is a no-op. That second
half only holds because of the "origin marker" rule below, which stops a marker alone from forcing
an empty journal.

The destructive hint on update deliberately differs from upstream. Clients use it to decide
whether to ask the person before calling, and an edit overwrites fields even though the journal
keeps the old values. Our `Base` defaults unannotated tools to `destructive: true`, so every tool
here sets its annotations explicitly.

All three act as the token's user and go through the same services as APIv3, so contracts and
permissions apply as they do over `/api/v3`, and so do the fork's own rules that live in
contracts: label governance, epic-link validation, the project-dependent attribute rules.

What I traced in this tree, so the review does not need to re-derive it:

- **`update_work_package` cannot post a comment or suppress notifications.** The APIv3 payload has
  no comment property (comments go through `/activities`), and `send_notifications` is set by the
  API from `?notify=`, never from the body. The tools never set it. Keeping comments in their own
  tool is what lets an administrator allow edits without allowing comments.
- **Failures are atomic.** The services run inside a transaction that rolls back on failure, so a
  rejected call writes nothing and the model can simply correct and retry.
- **`update_work_package` cannot delete a work package, but two things in `data` can destroy
  data.** Attachments are one (below). The other is a project change. Moving a work package to another project also moves its descendants, and when
  `cross_project_work_package_relations` is off it **destroys their relations**
  (`WorkPackages::UpdateService#cleanup`). Time entries and memberships are re-pointed too, and
  descendants get journals with no cause at all. An earlier draft of this proposal said "cannot
  delete" and was wrong on that point. **v1 rejects project changes in `update_work_package`**; an
  assistant can create a work package in the right project instead. Attachments:
  `_links.attachments` replaces the whole set, and `[]` deleted the existing attachment rows
  (measured), so it is blocked too. Changing the *type* resets
  custom values that do not apply to the new type, which is what the UI does too.
- **`lockVersion` stays mandatory** on update, with a description telling the model to re-read
  and retry on conflict. That is the guard against blind overwrites.

### What `data` may contain

**Policy: an allowlist on the parsed attributes, not a denylist.** The first draft rejected
`createdAt`, `updatedAt`, `author` and project changes by name. Review found attachments next, and
checking showed why a denylist keeps losing: the payload parser accepts more than the representer
calls writable. Measured, `WorkPackagePayloadRepresenter#writable_attributes` lists 25 names and
**omits** `attachments`, `fileLinks`, `author` and `createdAt`, all of which the parser turned into
attributes (`attachment_ids`, `file_links_ids`, `author_id`, `created_at`). The contract is the
real gate for most attributes, but attachments and file links have their own validators and bypass
it. A denylist would also let every property a future upgrade or module adds (the tree already has
`sprint_id`, `budget_id`, `position` and a project-phase link) become writable by an assistant
unnoticed. An allowlist makes the opposite true: new properties are refused until someone decides.

**Two checks, both before anything is written, either of which ends the call with a tool error
(`isError: true`) naming the problem:**

1. **Raw keys: what the model sent.** Every key of `data`, and every key inside `data._links`, must
   be one of the API names below. Anything else is refused and named, with the allowed names listed
   so the model can correct itself. This is what stops a typo, a `watchers` link, `meta`, `_type`,
   `id` or a `_links.self` from being silently dropped while the call reports success and the model
   believes it changed something. (An earlier draft promised an error for unsupported keys but
   checked only parsed ones, which the parser has already thinned out. The two statements
   contradicted each other.)
2. **Parsed attributes: what `ParseParamsService` produced.** Every parsed key must be in the parsed
   list. This is a backstop for a raw key that maps to an attribute nobody intended. A spec asserts
   that every allowed raw key parses into the allowed parsed set, so the two lists cannot drift.

| Allowed raw keys (API names) | |
|---|---|
| `subject`, `description`, `lockVersion`, `startDate`, `dueDate`, `duration`, `estimatedTime`, `remainingTime`, `percentageDone`, `scheduleManually`, `ignoreNonWorkingDays`, `storyPoints`, `customField<N>` | top level of `data` |
| `type`, `status`, `priority`, `assignee`, `responsible`, `parent`, `version`, `category`, `epic`, `customField<N>` | inside `data._links`; `project` as well, **on create only** |

The cost is deliberate: a model that reads a work package and sends the whole representation back
(`_type`, `id`, `createdAt`, `_links.self`, ...) gets an error listing exactly those keys, and
retries with only what it changed. The tool description says to send only the attributes to change,
as upstream's does.

Parsed key names, measured:

| Allowed | Notes |
|---|---|
| `subject`, `description`, `type_id`, `status_id`, `priority_id` | |
| `assigned_to_id`, `responsible_id`, `parent`, `version_id`, `category_id` | `parent` parses to a work package object |
| `epic` | the fork's epic link; parses to a work package object, not `epic_id` |
| `start_date`, `due_date`, `duration`, `estimated_hours`, `remaining_hours`, `done_ratio` | |
| `schedule_manually`, `ignore_non_working_days`, `story_points` | |
| `custom_field_<id>` | a long-text field must be sent as `{"raw": "..."}`; a bare string parsed to `nil` (measured), so the tool description must say so |
| `project_id` | **create only**; a project change on update is rejected |
| `lock_version` | always present; required on update |

| Refused | Why |
|---|---|
| `attachment_ids`, `file_links_ids` | replacement semantics; `[]` deletes. Attachments and file links are out of scope |
| `author_id`, `created_at`, `updated_at` | would let an assistant re-attribute or backdate, and the read-only-attribute path overwrites the journal cause |
| `budget_id`, `position`, `project_phase_definition_id`, `sprint_id` | not asked for; decide per property later |
| `project_id` on update | project moves destroy relations and write unmarked descendant journals |
| anything else, including `meta` | not on the list |

A successful call also answers with the resulting work package, so the model can see what was
actually stored. Specs: each allowed key is accepted; each refused key, including the empty
`_links.attachments: []`, is refused with nothing written and attachments intact; a typo, a
`watchers` link, `meta`, `_type`, `id` and an unknown `_links` key are each refused by the raw-key
check and named in the message; a round-tripped read representation is refused with its read-only
keys listed.

### Comments

Three points where the comment tool should be stricter than a plain call to the service, which is
what upstream's tool does:

1. **Check `add_work_package_comments` explicitly.** The UI's comment action is gated by that
   permission alone. `WorkPackages::CreateNoteContract` also accepts `edit_work_packages`, so
   calling the service directly would let a user comment through MCP who cannot in the UI. The
   tool checks the permission first, so MCP is never more permissive than the UI.
2. **Internal comments stay enforced by the contract.** `internal: true` requires the Enterprise
   `internal_comments` feature, the project setting, and `add_internal_comments`, all already in
   the contract. No extra work, but the tool must pass the flag through unchanged.
3. **Sanitize mentions in internal comments, as the UI does.** The UI runs
   `WorkPackages::ActivitiesTab::InternalCommentMentionsSanitizer` on internal notes, which turns
   mentions of people who cannot read internal comments into plain text. APIv3 and upstream's tool
   skip it. The MCP tool should apply it, which is one call.

**Residual risk, not enforceable in code:** an assistant can read internal comments (when the
user may) and then restate them in a public one. The `internal` parameter defaults to `false`,
matching the UI, and the tool description should say never to copy internal content into a public
comment. That is guidance to the model, not a control.

`list_work_package_comments` empties each activity's details, so an assistant reading comments
back will not see the marker below. A person in the UI will.

### Safeguards

#### Live by default, with an off switch

The tools are on as soon as the seeder has created their rows. `McpConfigurationSeeder` creates a
row for every registered tool it has not seen, with `enabled: true`, and that is the existing
behaviour, so **no new flag or code is needed**. (The alternative considered and dropped was a
`default_enabled` flag on `Base`, so a new instance would start with write tools off. It exists to
stop an upgrade enabling writes unannounced. With a single production instance whose owner is
managing the rollout, that protection is not needed.)

What this means for the one production instance:

- **Whether the tools appear depends on the seeder running.** The tool rows are what make a tool
  available (`McpTools.enabled_mcp_tools` reads them), so a deploy that never runs `db:seed` leaves
  the new tools absent. The stock Docker `seeder` service and the package postinstall both run
  `rake db:seed`. If your deploy does not, run it once; it is idempotent.
- **Connected assistants gain write access at that moment.** Every existing token and OAuth grant
  was issued on the documented understanding that MCP only reads. Tell the people who have
  assistants connected before the deploy. Some MCP clients ask for confirmation before calling a
  tool that is not marked read-only, but that is client behaviour, not something to rely on.
- **The off switch is per tool.** Untick a tool under Administration → MCP. The server object is
  rebuilt from the enabled rows on every request (`lib/api/mcp.rb:52`), so a switched-off tool
  should be refused immediately, even to a client that already connected. Comments are the tool
  most likely to need switching off on their own, since they notify people. I have not tested a
  call to a just-disabled tool on a write tool itself; it is under "Specs still to write".
- **Check it after deploy.** The "Verify end-to-end" `tools/list` call in the user guide should now
  return seventeen tools, and the marker query below shows what the assistants have written.

The admin tool table marks every tool that is not declared read-only with a "Modifies data" badge,
so it is clear which toggles stop assistants writing. It is cosmetic: nothing depends on it. A
resource, or a row whose tool is no longer registered, is never marked.

**Accepted risk.** Recorded so it is a decision on paper, not an omission. The owner of the single
production instance accepted this on 2026-10-13:

- Every credential that can reach `/mcp` today gains the ability to *attempt* create, edit and
  comment as soon as the tools are seeded: personal API tokens, OAuth and OIDC grants, and sessions
  all pass the same `mcp` authorization, and none of them is asked again. An attempt succeeds only
  where the token user's own permissions allow it (`add_work_packages`, `edit_work_packages`,
  `add_work_package_comments`, and the rest of the contracts), so access to `/mcp` alone does not
  grant writes. It does mean a credential issued for reading can now be used to write wherever its
  user could write.
- Client-side confirmation prompts are **not** treated as a control. They are client behaviour, not
  a server-side authorization boundary, and the off switch only helps once the capability is
  already on.
- The server-side *limits* are the token user's own permissions and the per-tool admin toggle. The
  journal marker is an **audit** mechanism: it makes assistant writes recognisable afterwards, and
  it prevents nothing.

**Rollback.** There is no migration and no schema change. Rolling back is unticking the tool(s)
under Administration → MCP, which needs no deploy; removing the code later leaves harmless
configuration rows. That is only a rollback plan once a write tool's own spec shows it refused
when disabled (listed under "Specs still to write"), so that spec gates the deploy.

**Stricter options, not taken:** write tools off until an admin ticks them (dropped on 2026-10-13),
or a separate `mcp_write` OAuth scope requiring renewed consent. The scope would bind only OAuth
and OIDC tokens: the other strategies on the MCP endpoint (API token, basic auth, session) do not
go through OAuth scopes as far as I could see in `config/initializers/warden.rb`, which I did not
trace further. So it would not close the gap by itself. Before deploying, check Administration → Authentication → OAuth applications for
any application holding the `mcp` scope that you do not control.

#### Agent marker on journals

**What it is.** A new cause, `Journal::CausedByMcp` (`cause.type = "mcp"`, `cause.tool` = one of
the three tool names), modelled on the fork's `Journal::CausedByGitlabEvent`. Like that class it
validates its input: an unknown tool raises `ArgumentError`, so nothing user-controlled reaches the
stored cause or the rendered text.

**What it needs.** Adding a cause type touches four places, and the first draft only named two:

1. `Journal::VALID_CAUSE_TYPES` gains `mcp`. **This one is load-bearing.** Journals are inserted
   with raw SQL, so the update path ignores the list, but the comment path validates the journal
   afterwards (in the attachment-claims step). Without `mcp` in the list, a comment fails with
   `success? == false`, an **empty error list**, and the journal rolled back. Measured. A new
   constant `Journal::ORIGIN_CAUSE_TYPES = %w[mcp]` names causes that only record where a journal
   came from (see the aggregation rules below).
2. **The formatter.** `OpenProject::JournalFormatter::Cause#cause_description` has a `case` whose
   `else` branch is `related_work_package_changed_message`, which looks up
   `cause["work_package_id"]`. An unknown type would fall into it and render the
   "unaccessable work package" text. So: a `when "mcp"` branch calling a new `mcp_message`, which
   reads `journals.cause_descriptions.mcp.<tool>` with a `default` fallback.
3. **Translations** in `config/locales/en.yml`: `journals.caused_changes.mcp` ("AI assistant
   (MCP):") and `journals.cause_descriptions.mcp.{create_work_package, update_work_package,
   create_work_package_comment, default}`.
4. **Journal creation** (`Journals::CreateService`), two rules, next section.

Unlike `gitlab_event` it must **not** go in `INTEGRATION_CAUSE_TYPES`: that list exists to *hide*
the cause line and to keep those journals out of the comments-only view. Here the point is to show
the line, and an agent's comment is a real comment that should stay in that view
(`Journal.user_comments` excludes only the integration types).

**How it reaches each tool:**

- **Update:** `journal_cause` is a plain attribute on the model, so it is passed through
  `UpdateService#call` like any other (existing callers: `work_package.rb:766`, the working-days
  job).
- **Create:** the same `SetAttributesService`. Measured: the initial journal carries the cause.
- **Comment:** `work_package.add_journal` already takes `cause:`, but
  `AddWorkPackageNoteService` did not pass it. **Done:** `call(notes, ..., cause: nil)` forwards it
  only when given, so the UI, APIv3 and BCF-import callers, and the existing spec's argument
  expectations, are untouched. The cause is cleared again if the comment is refused. An earlier
  version of the specs set `work_package.journal_cause` directly and so never exercised this
  argument; they now call it.

**Two rules in journal creation, both required.** An earlier draft claimed "journal aggregation
only merges journals with an identical cause". That was wrong. `Journals::CreateService`
(`only_one_or_same_cause?`) merges when the predecessor's cause is empty, **or** the new cause is
blank, **or** the two are equal, and the merge rewrites the stored cause
(`update_journal_sql` sets `cause = :cause`). With the same user inside the aggregation window
(`journal_aggregation_time_minutes`):

| Sequence | Today's behaviour | Effect |
|---|---|---|
| person edits, then assistant edits | merged, cause becomes `mcp` | the person's changes are labelled as the assistant's |
| assistant edits or comments, then person edits | merged, cause becomes `{}` | **the marker is erased** |

The second row is the dangerous one, and it is realistic: ask the assistant to comment, then change
a field yourself a minute later. Separately, a cause forces a journal even when nothing changed
(`only_on_changed_or_forced_condition_sql`), so a repeated no-op update would write an empty
"changed through an assistant" journal, and possibly notify.

The fix is to treat `Journal::ORIGIN_CAUSE_TYPES` specially in `Journals::CreateService`:

1. **No aggregation across origins.** If the predecessor's cause or the new cause is an origin
   cause, aggregate only when the two causes are identical (same tool). Otherwise start a new journal.
2. **An origin cause never forces a journal.** In `only_on_changed_or_forced_condition_sql`, an
   origin cause counts as blank. It rides on a journal that exists because something changed or a
   note was written, and is never the reason for one.

This is a change to a core service, so it needs its own spec in the existing
`Journals::CreateService` spec file, and it must leave every existing cause (`import`,
`system_update`, the scheduling causes, `gitlab_event`) behaving exactly as before.

**A call can save the same work package more than once.** A save consumes the journal cause, so a
second save in the same call would write an unmarked journal. Measured on both paths with a
pattern-generated subject (the `{{id}}` token only exists after the first save):

| Path | Without a hand-off | Cause |
|---|---|---|
| `CreateService` | journal 1 marked, journal 2 **unmarked**, both by the token user | `apply_patterns` saves again |
| `UpdateService` | journal 2 marked, journal 3 **unmarked** | the subject is saved a second time by `UpdateAncestorsService` |

Under the *old* aggregation rules the second save would instead have merged into the first and
**erased** the marker, so this is the same hazard as before, seen from inside one call. Fix, in the
working tree: `WorkPackages::Shared::CarryOriginCause`, included by both services, re-applies the
origin cause to the work package before its follow-up saves and releases it in an `ensure` around
the whole call, so it cannot leak into the caller's next save. An earlier version released it only
at the end of the happy path; an exception between the hand-off and the release, or a failed
validation (the cause is assigned with the other attributes, so it is on the instance even when
nothing is saved), left an assistant's cause on an object the caller might save later and mislabel.
Specced for create and update raising, create and update failing validation, and a refused comment;
each of those examples fails when the `ensure` is removed. It only acts on an origin cause, so every existing cause (and the
working-days job, duplicate closing and the rest) behaves exactly as before. Because the two saves
then carry an identical cause, they aggregate into **one** marked journal. Scheduling a created work
package did not reproduce an extra save of the work package itself (a child of an automatically
scheduled parent produced one journal); the hand-off covers it if it ever does.

**Dependent journals are not marked.** One call can write more than one journal, for *other* work
packages. Reading
`UpdateService` and the services it calls:

| Side effect | Journal it writes |
|---|---|
| Parent roll-up of **dates** (`SetScheduleService`) | cause `work_package_related_changed_times`, naming the edited work package (measured) |
| Parent roll-up of **totals** such as estimated hours (`UpdateAncestorsService`) | a system note, "Updated automatically by changing values within child work package #N", no cause (measured) |
| Followers rescheduled (`SetScheduleService`) | cause `work_package_related_changed_times`, naming the work package that initiated it (the one the assistant edited) |
| Descendants moved with a project change | no cause. **Not reachable in v1**, because project changes are rejected |

So the guarantee is narrower than "every journal": **the journal(s) the call writes for the work
package it targets are marked, as one journal.** The side-effect journals are attributed to the token's user like any
other, and each already names the primary work package, so they trace back to the marked journal.
Passing the marker down as the rescheduling cause would work mechanically but would replace "by
changes to predecessor #N" on every follower with a generic label, losing information a person
needs. So we do not propagate it.

**Where the marker shows.** Rendered through `ItemComponent` for each filter of the activity tab
(measured, with a stand-in cause):

| Journal | All | Comments only | Changes only |
|---|---|---|---|
| Attribute change with a cause | cause line shown | n/a | cause line shown |
| Comment with a cause | comment **and** cause line shown | comment shown, **cause line not shown** | cause line shown, comment not |

So on a comment, the marker is invisible in the "comments only" view, because that view renders
only an empty line where the details go. That is the view where an assistant's comment most needs a
label, since it reads as the person speaking. **Recommended: a small "AI assistant" label in the
comment header when `journal.cause_type == "mcp"`**, which works in every filter. It is a few lines
in `ItemComponent` plus a component spec. See decision 11.

**Using it.** `Journal.where("cause->>'type' = 'mcp'")` lists the journals an assistant
wrote for the work packages it targeted. It does not list side-effect journals; follow the work package named in those. Document
both for administrators.

What it does not do: identify *which* assistant. The token's user and the cause are the same for
every client. Recording the OAuth application name is possible later if it matters.

**Edge, closed by the allowlist.** `SetAttributesService#set_cause_for_readonly_attributes`
overwrites `journal_cause` when `created_at`, `updated_at` or `author` change. That path needs an
admin with `apiv3_write_readonly_attributes` on, but it would let an assistant backdate or
re-attribute a journal *and* drop the marker. Those three keys are not on the allowlist.

#### Notifications

All three tools notify the way the UI does: assignee, responsible, watchers and mentioned users,
per their own settings. The creating user also becomes a watcher of a work package they create,
as in the UI. **Recommended: keep it that way and do not expose a `notify` option to the model.**
A silent reassignment or comment is worse than a noisy one. The residual risk is volume, since a
model looping over fifty work packages sends fifty sets of notifications; the per-tool toggle is
the brake.

#### Errors

Existing tools return `{ error: "..." }` as a normal result, which a client reads as success, and
`Base#handle_request` always wraps a tool's return value as a successful response. Write tools
need a real protocol-level error, so:

- A small value type, `McpTools::Failure` (a message), which a tool's `call` returns.
- `Base#handle_request` branches on it and builds
  `MCP::Tool::Response.new([{ type: "text", text: message }], error: true)` (the gem we pin, 0.24,
  supports the `error:` keyword). It skips the output filters and the structured-content step, and
  always sends text content whatever `mcp_tool_response_format` says, because a client needs the
  message.
- The contract's validation messages go in the text so the model can correct itself and retry.
- Existing read tools are untouched; their `{ error: ... }` behaviour stays as it is.

Specs must assert `result.isError == true` at the protocol level. The shared example
`"MCP tool execution error response"` in `spec/requests/api/v3/support/mcp_examples.rb` already
does that, so each write tool's failure cases use it, rather than checking an `{ error: ... }` body.

### Discoverability: the assistant can only set what it can find

An assistant writes `_links` by ID, so it needs a way to look every ID up. Checked against the
registered tools:

| Needed to set | Lookup | |
|---|---|---|
| project, type, status, assignee, version, parent, epic | `search_projects`, `list_types`, `list_statuses`, `search_users`, `search_versions`, `search_work_packages` | present |
| **priority** | `list_priorities` | **built**: it would otherwise only have been able to accept the default. |
| **Labels and any other list-format custom field** | none. `search_custom_field_items` returns an empty list for anything that is not a hierarchy field | **gap, deferred**: the assistant cannot set labels. Phase 2. |

The tool descriptions say to resolve IDs through the search tools first, and not to guess. That is
guidance. Because an ID that does not exist is not always an error, the tools also enforce it where
it matters; see below.

**Three links quietly default.** Probed with an ID that does not exist (999999): `assignee`,
`responsible`, `category`, `parent`, `epic`, `version` and `project` fail with the contract's own
message, but **`type`, `status` and `priority` succeed**, and the work package is created with the
project's default instead. The core fills those three in when empty
(`SetAttributesService#assign_default_type` and its siblings), and an ID that does not resolve counts
as empty. APIv3 behaves the same, but it is the silent substitution this design set out to close: an
assistant that guessed a type ID would be told it succeeded while a work package of another type was
made. Both write tools now refuse an ID that is given but does not exist, name the list tool to use,
and write nothing. Leaving the link out is still a deliberate request for the default, and is
specced as such.

### What an administrator and a user see

- **OAuth consent.** `oauth.scopes.mcp_text` described "a limited subset of APIv3, tailored for
  usage with AI agents" and did not mention writing. **Reworded**: it now says the app can create and
  edit work packages and add comments on the user's behalf, wherever their permissions allow, and
  that its changes are marked. The `mcp` scope is shared by every MCP auth strategy
  (API token, OAuth, OIDC, basic, session), so a separate write scope would only bind OAuth and
  OIDC tokens. Not worth it in v1.
- **Existing OAuth grants** gain write capability when the tools go live, which is why the consent
  text changes and why the rollout notes above say to tell connected users first.

## Decisions

| # | Decision | Status |
|---|---|---|
| 1 | Reverse the August verdict | **Decided: yes.** |
| 2 | Comments in scope | **Decided: yes.** |
| 3 | Ship disabled or enabled | **Decided: live by default.** One production instance; per-tool off switch in the admin page. |
| 4 | Notify as the UI does, no `notify` input | **Built.** |
| 5 | Visible agent marker on journals | **Built**: `cause.type = "mcp"`. |
| 6 | Expose `internal` on the comment tool | **Built**: default `false`, as the UI does. |
| 7 | Restrict by project or role | Not in v1. The token user's own permissions already bound it; the toggle is instance-wide. If finer control is wanted, a role permission is the natural mechanism and needs its own design. |
| 8 | Destructive hint on update | **Built**: on, deviating from upstream. |
| 9 | Origin markers never force a journal and never merge with a different cause (a change to `Journals::CreateService`) | **Built**, and required: without it the marker can be erased or can label a person's changes. |
| 12 | Allowlist, checked on the raw keys the model sent and on the parsed attributes, instead of a denylist | **Decided and built.** The parser accepts more than the representer calls writable, so a denylist already missed attachments, and it silently drops what it ignores, so checking only parsed keys hides typos. |
| 11 | Label an assistant's comment in the comment header, so it is visible in the comments-only view | **Decided and built.** Without it the marker on a comment is invisible in the comments-only view. |
| 10 | Reject project changes in `update_work_package` for v1 | **Built**: removes the unmarked descendant journals and the relation, time-entry and membership side effects. |

## Work breakdown

### Done: phase 1, in the working tree, uncommitted

**The tools** (all registered; enabled by the seeder like the others):

| Tool | File |
|---|---|
| `create_work_package` | `app/services/mcp_tools/create_work_package.rb` |
| `update_work_package` | `.../update_work_package.rb` |
| `create_work_package_comment` | `.../create_work_package_comment.rb` |
| `list_priorities`, so an assistant can set a priority | `.../list_priorities.rb` |

**What they stand on:**

| Change | Where |
|---|---|
| `McpTools::Failure` and the `isError: true` branch; `error_text` | `app/services/mcp_tools/failure.rb`, `base.rb` |
| The allowlist on raw and parsed keys, and its message | `app/services/mcp_tools/work_package_data.rb` |
| The shared sequence: allowlist, parse, backstop, refuse unknown type/status/priority IDs, stale-lock guidance | `app/services/mcp_tools/work_package_writer.rb` |
| `mcp` is a valid cause type; `ORIGIN_CAUSE_TYPES`; `Journal.origin_cause?` | `app/models/journal.rb` |
| `Journal::CausedByMcp`, with a closed list of tool names | `app/models/journal/caused_by_mcp.rb` |
| An origin cause aggregates only with an identical cause, and never forces a journal | `app/services/journals/create_service.rb`, `.../create_service/helpers.rb` |
| An origin cause survives a service's follow-up saves, and is released in an `ensure` | `app/services/work_packages/shared/carry_origin_cause.rb`, used by `WorkPackages::CreateService` and `UpdateService` |
| `AddWorkPackageNoteService#call` takes an optional `cause:` | `app/services/add_work_package_note_service.rb` |
| Formatter branch and translations | `lib/open_project/journal_formatter/cause.rb`, `config/locales/en.yml` |
| The "AI assistant" label in the comment header | `app/components/work_packages/activities_tab/journals/item_component.{rb,html.erb}` |
| OAuth consent wording | `config/locales/en.yml` (`oauth.scopes.mcp_text`) |
| The "Modifies data" badge on the admin tool table | `app/components/mcp_configurations/edit_row_component.rb`, `config/locales/en.yml` |
| Docs | `docs/features/MCP_FEATURE_GUIDE.md`, `docs/system-admin-guide/integrations/mcp-server/README.md`, `docs/development/mcp-upstream-backlog.md` |

**Specs: about 400 new examples**, written before the code they cover, in these files:

| Spec | Examples |
|---|---|
| `spec/requests/mcp/mcp_tools/create_work_package_spec.rb` | 109 |
| `.../update_work_package_spec.rb` | 122 |
| `.../create_work_package_comment_spec.rb` | 65 |
| `.../list_priorities_spec.rb` | 23 |
| `spec/services/mcp_tools/work_package_data_spec.rb`, including every supported key through the real parser | 27 |
| `spec/services/journals/create_service_origin_cause_spec.rb` | 26 |
| `spec/models/journal/caused_by_mcp_spec.rb`, including a guard that the closed tool list matches the registered write tools | 7 |
| `spec/components/.../item_component_spec.rb`, the label in every activity filter | 5 |
| `spec/seeders/mcp_configuration_seeder_spec.rb`, rollout behaviour | 5 |
| `spec/components/mcp_configurations/edit_table_component_spec.rb`, the badge | 9 |
| `.origin_cause?` in `spec/models/journal_spec.rb`; the formatter in `.../cause_spec.rb`; `cause:` in `add_work_package_note_service_spec.rb` | 7, 8, 3 |

**Regression, 2026-10-13:** 3,615 examples across the MCP, journal, work package service,
formatter, activity-tab, i18n and seeder specs, plus the activities API and controller specs.
**39 failures, none caused by this work.** Every one fails identically with these changes stashed:
the 37 found earlier, plus two in `spec/lib/i18n/human_attribute_name_spec.rb`, which I had not
included in the earlier baseline and confirmed by stashing the locale file. They all come from
missing English translations (`label_custom_comment`, `journals.cause_descriptions.import.*`) and
sprint journaling. Rubocop is clean apart from nine offenses on lines that were already there; erb_lint
is clean.

### Spike results (run 2026-10-13, scratch specs against the code)

| Question | Result |
|---|---|
| Does the initial journal on create carry `journal_cause`? | **Yes.** |
| Does the activity tab render the cause? | **Yes** in "All" and "Changes only". **Not** in "Comments only" for a comment journal; see decision 11. |
| Does `ParseParamsService` accept string-keyed `data` end to end? | **Yes.** Create succeeded, with a cause. Update parses to `lock_version` plus the changed keys, so a project change shows up as `project_id`. |
| Is a just-disabled tool refused? | **Covered per request.** The "MCP text tool" shared example asserts a JSON-RPC error when the tool's configuration is disabled, and each request builds its server from the enabled rows. Every write tool spec inherits it. Not yet exercised on a write tool, since none exist. |
| Aggregation, both orders | **Confirmed**: person then assistant merges and relabels; assistant then person merges and **erases the marker**, for edits and for comments. |
| No-op update with a cause | **Confirmed**: writes an empty journal, fires `JOURNAL_CREATED`, and **notifies the assignee** (one notification, same as a real change). |
| Project change | **Confirmed**: destroys relations when cross-project relations are off; descendants' journals have no cause. |
| A comment with an unlisted cause type | **Fails silently** (see the `VALID_CAUSE_TYPES` note above). |
| `_links.attachments: []` on update | **Deletes the existing attachment rows.** Another work package's attachment is refused by the contract; the user's own unclaimed upload is attached. |
| `_links.fileLinks` | Parses to `file_links_ids`; same replacement route. Not run end to end, blocked regardless. |
| Does the parser accept more than `writable_attributes`? | **Yes**: attachments, file links, author and timestamps are accepted but not listed. Hence the allowlist. |
| Watchers through `data` | **Not possible**: no attribute is produced. |
| A pattern-generated subject, on create and on update | **A second unmarked journal** without the hand-off; one marked journal with it. Scheduling a created work package did not re-save it. |

### Known gaps in the specs

Behaviour I checked with scratch specs earlier, but that has no spec in the repo for the *tools*:

- A follower rescheduled by an edit, and a parent whose **totals** (not dates) roll up, each keeping
  its own cause or note and not being marked. The parent-dates case is specced in
  `update_work_package_spec.rb`; the other two are only covered at the journal-service level.
- That creating a work package subscribes the creator as a watcher *without* a notification. The
  subscription is asserted; the absence of a notification is not.
- File links were only parsed, never attached or replaced, so "same replacement route as attachments"
  is read from the code. The allowlist refuses them either way, and that is specced.

**Phase 2: separate decisions, not part of this proposal**

- List-format custom field options (Labels), scoped to the project and honouring label governance.
- Relations; editing or deleting comments.
- Allowing attachments or file links, if ever, as additive operations that cannot replace the set.
- Recording the OAuth application name on the cause.

## Documentation changes

**Done**, in the same working tree as the code, since the docs are tied to this change:

- **MCP_FEATURE_GUIDE.md.** "It only reads" and "It cannot write" replaced; the tool count and tool
  tables updated (fourteen read tools, three write tools); the "declined" callout, "Read-only. By
  design" and "No agent audit trail" removed or replaced with the marker, the console query,
  notifications and the internal-comment caveat; create, edit and comment prompts added; how to switch
  the write tools off.
- **system-admin-guide/integrations/mcp-server/README.md.** A "Tools that change data" section: the
  three tools, that they are on like the others, how to switch them off, what they obey, the
  allowlist, notifications, the marker and how to audit it.
- **mcp-upstream-backlog.md.** Item 4 marked reopened, with what was taken, what was changed from
  upstream and why; the August review kept beneath it as the record.

Still true, and worth re-running before relying on any of it: the upstream comparison dates from
2026-10-13.

## Verified, and not

Verified in this tree or against `opf/openproject` (read through the GitHub API on 2026-10-13):
the registered tools and annotations; seeder behaviour and `RootSeeder` wiring; the three
services, `ParseParamsService`, and how APIv3 and the UI set `send_notifications`; the journal
cause mechanism, `gitlab_event` precedent, and `add_journal`'s `cause:` parameter; the
aggregation predicate and the SQL it drives (`only_one_or_same_cause?`, `update_journal_sql`,
`only_on_changed_or_forced_condition_sql`); the formatter's `else` fallthrough; the cause each
dependent service assigns; that `after_save :save_journals` runs on a no-change save; the note
contract's permission and internal-comment checks against the UI's permission mapping; the mentions sanitizer; that nothing in the notification code keys on `cause`; the
payload representer's lack of a comment property; upstream's tool source and the 17.8 and 17.9
release notes; `MCP::Tool::Response` in gem 0.24. **Run, not just read** (scratch specs and the new
repo specs, 2026-10-13): aggregation in both orders; the no-op journal and its notification; the
create and update re-save lifecycle; the attachment deletion; the parsed key names; the activity-tab
rendering per filter; and the regression run described under "Done".

**Not verified:** the tools are exercised through `POST /mcp` in request specs, with a real OAuth
token and the real contracts, but never against a running server with a real MCP client; file links
were only parsed, never attached or replaced, so the claim that they behave like attachments is from
the code, not a run; that the contracts fire for the MCP path is shown for the core ones (unknown
parent, epic, version and category all fail with the contract's message) but **not for label
governance**, and an assistant cannot set labels at all yet; whether any given MCP client shows the
destructive hint as a confirmation prompt; the exact set of people notified on create and on comment; whether an assistant can in practice
produce a valid mention tag (plain `@name` text may not create a mention at all, so the sanitizer
may rarely matter); and anything about the live deployment, including whether `db:seed` runs on
deploy in your setup. With tools live by default that now matters in the other direction: the new
tools only appear once the seeder has created their rows.

## Changes after review

An independent review on 2026-10-13 raised five issues. Each was checked against the code before
this revision. All five were correct, and checking them turned up one more error in the first draft.

| Finding | Disposition |
|---|---|
| High: aggregation can hide or mislabel the marker | **Confirmed**, and worse than stated: the merge rewrites the cause, erasing it when a person edits after the assistant. Fixed by the origin-cause rules in `Journals::CreateService`; both orders specced. My earlier "only merges identical causes" claim was wrong. |
| High: "every journal" is not marked | **Confirmed.** Claim narrowed to the target work package's journal; side-effect journals already name it. Project changes rejected in v1 so the one unmarked path is unreachable. |
| High: live-by-default upgrades existing grants | **Accepted by the owner, recorded** with the exact scope of the risk and the rollback. Gated on a write tool's disabled-tool spec. Stricter options listed, not taken. |
| Medium: formatter design incomplete | **Confirmed**: unknown types fall into `related_work_package_changed_message`. Branch, `mcp_message` and translation keys specified; HTML and plain-text specs added. |
| Medium: `update_work_package` not idempotent | **Confirmed**: a cause forces a journal with no changes. Fixed by "an origin cause never forces a journal"; idempotency now defined. |
| Detail: `Base` needs a real error branch | Specified: `McpTools::Failure` and an `isError: true` branch; specs assert the protocol-level flag. |
| Found while checking: "`update_work_package` cannot delete" | **Wrong in the first draft.** A project change destroys relations when cross-project relations are off. Corrected above. |

### Found while building phase 1 (2026-10-13)

- **Type, status and priority silently default** when given an ID that does not exist, in the core and
  so in APIv3 too. Found by probing every link with a nonexistent ID rather than assuming; the tools now
  refuse it.
- **A stale `lockVersion` answered "Information has been updated by at least one other user in the
  meantime."**, which tells an assistant nothing to do. The error is now recognised by its key and
  followed by the instruction to read again and retry.
- **Rubocop's `Metrics/AbcSize` was right** about `checked_attributes` and two `call` methods; they were
  split. A leading `%(` after a line continuation parses as the modulo operator, which broke a spec
  until the fixture was rewritten.
- **The earlier regression runs had omitted `spec/lib/i18n`**; the first full run also listed a
  directory that does not exist and ran nothing (0 examples). Both are corrected, and the two extra
  failures that appeared were shown to be pre-existing by stashing the locale file.

### Third review (2026-10-13)

Three more, checked the same way. All three held.

| Finding | Disposition |
|---|---|
| High: releasing the cause is not exception-safe | **Confirmed**, and wider than stated: it also leaked when validation failed, because the cause is assigned with the other attributes. Moved into an `ensure` for create and update; the comment path clears it too. Specs for raising, failing and refused cases, and each fails without the `ensure`. |
| Medium: the allowlist does not reject parser-ignored fields | **Confirmed**: the proposal both promised an error for unsupported keys and said typos and watchers were silently ignored. Fixed in the design with a raw-key check before the parsed-key check. Design only; the tools are not built. |
| Medium: the comment specs never used the intended `cause:` argument | **Confirmed**: they set `journal_cause` on the work package directly. The argument is now implemented (forwarded only when given) and the specs call it. |

### Second review (2026-10-13)

A second review raised four more. Checked the same way; all four held.

| Finding | Disposition |
|---|---|
| High: attachments are writable though out of scope | **Confirmed, and destructive**: `_links.attachments: []` deleted the work package's attachment rows. Fixed in the design by an **allowlist** rather than a longer denylist, because the parser accepts keys the representer does not list as writable (attachments, file links, author, timestamps). File links are covered by the same list. |
| High: create writes further unmarked primary journals | **Confirmed on create, and also on update**, which the review did not mention: a pattern-generated subject re-saves the work package. Fixed and specced: `CarryOriginCause`, acting only on origin causes, leaving one marked journal. Scheduling a created work package did not reproduce an extra save. |
| Medium: watchers out of scope, yet creating one subscribes the creator | **Confirmed.** `data` cannot manage watchers (measured); the creator subscription is a service side effect and is kept, now stated in the scope. |
| Medium: accepted-risk wording overstates | **Correct.** `/mcp` access alone grants no writes; the user's permissions still decide. And the marker is an audit mechanism, not a limit. Both reworded. |

Found while checking, mine: the first version of `Journal` origin-cause detection raised on a String
cause and broke 22 existing examples. The wider regression run caught it, and it is fixed and
specced. Also: the 37 pre-existing failures in this area are unrelated missing English translations.
