# Connect an AI assistant to OpenProject (MCP)

This build ships an **MCP server**: a single endpoint that lets an AI assistant —
Claude Code, Claude Desktop, or any other MCP client — read data out of this
OpenProject instance, and create and edit work packages and comment on them.

Ask "what's still open in the Website Redesign project?" and the assistant queries
OpenProject directly instead of guessing or asking you to paste anything in. Ask it to
"create a task for the login bug and assign it to Sam" and it does that too.

Three things are worth knowing up front:

- **It can write, a little.** It can create work packages, edit them, and add comments.
  It cannot delete anything, manage relations, or touch attachments. See
  [What it can and can't do](#what-it-can-and-cant-do).
- **It acts as you.** Every request runs as the user whose token the client holds,
  through the same permission checks as the rest of OpenProject. An assistant cannot
  surface a project you have no access to, and cannot change what you may not change.
  What it writes carries your name, so it is **marked as written by an AI assistant**.
- **Whoever it notifies is notified.** Creating, editing and commenting notify the
  people the OpenProject UI would notify. The assistant cannot turn that off.

> Upstream OpenProject sells MCP as an Enterprise add-on. This build removes that
> restriction, so the feature works without an Enterprise token.

> This guide doubles as a verification checklist. Follow the **Setup** once, then run
> **[Verify end-to-end](#verify-end-to-end)** to confirm it works.

---

## Contents

- [How it works (at a glance)](#how-it-works-at-a-glance)
- [Setup (one time)](#setup-one-time)
  - [1. Administrator — turn the server on](#1-administrator--turn-the-server-on)
  - [2. Each user — get a token](#2-each-user--get-a-token)
  - [3. Each user — point your client at OpenProject](#3-each-user--point-your-client-at-openproject)
- [Using it](#using-it)
- [Verify end-to-end](#verify-end-to-end)
- [What it can and can't do](#what-it-can-and-cant-do)
- [Tuning what the assistant sees](#tuning-what-the-assistant-sees)
- [Troubleshooting](#troubleshooting)
- [Notes & limitations](#notes--limitations)

---

## How it works (at a glance)

| Layer | Who sets it | What |
|---|---|---|
| **MCP server** | Administrator | Turned on once for the whole instance |
| **Token** | Each user | Proves who you are; MCP acts as you |
| **Client config** | Each user | Points your AI tool at `/mcp` |

The endpoint lives at **`/mcp`** — for example
`https://openproject.example.com/mcp`. There is one endpoint for the whole
instance; there is nothing to enable per project.

---

## Setup (one time)

### 1. Administrator — turn the server on

1. Go to **Administration → Artificial Intelligence (AI) → Model Context Protocol (MCP)**
   (direct URL: `/admin/mcp_configurations`).
2. Tick **Enabled** and press **Update**.
3. Optionally set the **Title** and **Description**. These are what a connecting
   client sees when it asks the server to identify itself, so something like
   "Acme OpenProject" is more useful than the default.

Once enabled, the page grows two more sections — **Tools** and **Resources** —
listing everything the server exposes. The defaults are fine to start with; see
[Tuning what the assistant sees](#tuning-what-the-assistant-sees) if you want to
narrow or rename them later.

> Until **Enabled** is ticked, `/mcp` returns `404` no matter how a client is
> configured. This is the first thing to check when a client won't connect.

### 2. Each user — get a token

Which kind of token depends on where your MCP client runs.

**A personal API token** — for a client running on your own machine
(Claude Code, Claude Desktop). Simplest option, no admin involvement.

1. Go to **My account → Access tokens** (direct URL: `/my/access_tokens`).
2. On the **Provider tokens** tab, find **API** and press the **API token** button.
3. Copy the token immediately — it is shown once and never again.

> If the API section says tokens aren't enabled, an administrator has switched off
> "Decide whether users can create personal API tokens in their account settings"
> and needs to turn it back on.

**OAuth** — for a shared or web-based MCP client used by more than one person, so
each person's requests run as themselves. An administrator prepares this once:

1. **Administration → Authentication → OAuth applications → +**.
2. Grant the application the **Access to MCP** scope.
3. Set the **Redirect URI** to whatever your MCP client documents.
4. Mark the application **confidential**.

Users then authorize the app through the normal OAuth prompt, which will name the
MCP permission explicitly. Tokens from a compliant OpenID Connect provider work
too, as long as they carry the `mcp` scope.

### 3. Each user — point your client at OpenProject

The endpoint is `https://<your-openproject-host>/mcp`, authenticated with HTTP
Basic auth: the username is the literal string **`apikey`** and the password is
your token.

For **Claude Code**, the one-liner is:

```bash
claude mcp add --transport http openproject https://openproject.example.com/mcp \
  --header "Authorization: Basic $(printf 'apikey:%s' "$YOUR_TOKEN" | base64)"
```

For clients configured through a JSON file, the same thing looks like:

```json
{
  "mcpServers": {
    "openproject": {
      "type": "http",
      "url": "https://openproject.example.com/mcp",
      "headers": {
        "Authorization": "Basic <base64 of apikey:YOUR_TOKEN>"
      }
    }
  }
}
```

Generate that base64 value with `printf 'apikey:%s' "$YOUR_TOKEN" | base64`.

> Treat the token like a password — it grants everything your account can read.
> Prefer whatever secret storage your client offers over committing it to a config
> file, and revoke it under **My account → Access tokens** if it leaks.

---

## Using it

There is no OpenProject UI for this. Once connected, just ask your assistant
questions in plain language and it decides which tools to call:

- "What work packages are assigned to me and still open?"
- "List the projects under the Infrastructure program."
- "What's in the 2026 Q3 version of the Website Redesign project?"
- "Who's on the Website Redesign project?"
- "Summarise the discussion on work package 1234."
- "What's blocking work package 1234?"
- "Create a bug in the Website Redesign project: the login page returns a 500."
- "Set work package 1234 to In progress and assign it to Sam."
- "Add a comment to work package 1234 saying the fix is on staging."

Ask for the change in words you would use to a colleague. The assistant looks up the
project, type, status, priority and people it needs by ID before writing, so name them the
way OpenProject does.

Two habits make answers noticeably better:

- **Name projects and versions the way OpenProject does.** The assistant matches on
  real names and identifiers.
- **Ask for a follow-up rather than a huge sweep.** Each search returns at most 40
  results per call, though it also reports how many matches there are in total, so
  the assistant can page through the rest if you ask
  (see [Notes & limitations](#notes--limitations)).

---

## Verify end-to-end

The quickest check needs nothing but `curl`. Ask the server to list its tools:

```bash
curl -s -u "apikey:$YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  https://openproject.example.com/mcp \
  -d '{"jsonrpc":"2.0","id":"1","method":"tools/list","params":{}}'
```

A working setup returns JSON containing a `result.tools` array with entries like
`search_work_packages`. Then check the whole path end-to-end from your assistant
by asking something only OpenProject could answer, such as "using OpenProject, who
am I?" — that exercises the `current_user` tool and confirms your token is
resolving to the right account.

| What you get back | What it means |
|---|---|
| `result.tools` array | Working |
| `404` with "MCP server is not available." | Server not enabled in Administration |
| `200` but `result.tools` is empty | Server is on, but every tool has been disabled |
| `401` | Token wrong, expired, revoked, or missing the `mcp` scope |

---

## What it can and can't do

**It can read**, through fourteen tools:

| Tool | Answers |
|---|---|
| `search_work_packages` | Work packages by assignee, author, ID, project, status, type, version, or partial subject |
| `search_projects` | Projects by name, identifier, or status |
| `search_programs` | Programs (the project level above projects) |
| `search_portfolios` | Portfolios (the level above programs) |
| `search_versions` | Versions by name |
| `search_users` | Users by name |
| `list_work_package_comments` | The discussion on a work package, newest first |
| `list_work_package_relations` | What a work package relates to, follows, or blocks |
| `search_custom_fields` | Custom fields by ID or partial name — this is how an assistant turns `customField7` into a real name |
| `search_custom_field_items` | The values available for a hierarchy custom field |
| `list_statuses` | Every work package status on the instance |
| `list_priorities` | Every work package priority on the instance, in order, with whether it is active |
| `list_types` | Every work package type on the instance |
| `current_user` | Who the token belongs to |

Alongside these it exposes ten **resources** — by-ID lookups of a single project, work
package, user, version, type, status or custom field, plus the current user and the full
status and type lists — which a client can fetch without a search.

**It can write**, through three tools, and nothing else:

| Tool | Does |
|---|---|
| `create_work_package` | Creates a work package |
| `update_work_package` | Changes a work package. It must send the `lockVersion` it read, so an update is refused if someone changed the work package meanwhile |
| `create_work_package_comment` | Adds a comment, public or internal |

It **cannot** delete anything, create or change relations, edit or delete a comment, add
attachments or file links, manage watchers, or move a work package to another project. A
request that includes any of those is refused with a message naming them, and nothing is
written. Only a fixed set of work package attributes can be sent: the subject, description,
type, status, priority, assignee, responsible, parent, version, category, epic, dates,
duration, estimated and remaining time, percent complete, scheduling mode, story points, and
custom fields. Anything else, including a typo, is refused rather than ignored.

**What it writes is marked.** A change an assistant made is shown in the activity as
"AI assistant (MCP)", and a comment it wrote carries an "AI assistant" label next to your name
wherever the comment is shown. It is still recorded under your name, because it acted as you. Administrators can
list everything assistants wrote with `Journal.where("cause->>'type' = 'mcp'")` in a Rails
console. That lists the journals written for the work packages an assistant targeted. Side
effects, such as a parent whose dates rolled up, are recorded as the automatic changes they
are and name the work package that triggered them; they are not in that list.

**It cannot exceed your permissions.** Every query is scoped to what the token's
user can see. Two people connecting the same assistant to the same instance get
different answers, correctly.

> Upstream also ships tools for relations and time entries. They are **not** in this
> build. The write tools that are here were reviewed, narrowed and given an audit marker
> before being taken; see [mcp-write-tools-proposal.md](../development/mcp-write-tools-proposal.md)
> for the reasoning and
> [mcp-upstream-backlog.md](../development/mcp-upstream-backlog.md) for what remains.

---

## Tuning what the assistant sees

Everything below is on the admin page, under **Tools** and **Resources**, and takes
effect on the next client connection.

**Turn individual tools off.** Unticking a tool removes it from the server
entirely — clients stop being offered it, and a call to it is refused. Useful for
narrowing what an assistant can reach without switching MCP off wholesale. **This is how
you stop an assistant writing**: untick `create_work_package`, `update_work_package` and
`create_work_package_comment`. Comments are the one most worth switching off on its own,
since they notify people. The write tools are on by default, like the others.

**Rename tools to match your vocabulary.** Each tool's title and description are
editable, and the assistant reads both when deciding what to call. If your team
says "work items" rather than "work packages", renaming *Search work packages* to
*Search work items* measurably improves the assistant's choices — it gives the
model an explicit cue that the two terms mean the same thing.

**Spot the tools that write.** The tools that can change data carry a "Modifies data" badge in
the list, so you can see which boxes to untick to stop assistants writing.

**Change the response format** if your client seems to receive everything twice.
The **Tool response format** setting offers:

| Option | When |
|---|---|
| **Full** (default) | Most compatible. Sends both plain-text and structured content, letting the client pick. Costs more tokens. |
| **Structured content only** | Your client definitely supports structured content. Leaner. |
| **Content only** | Your client does not support structured content. |

Leave this on **Full** unless you have a concrete reason — a wrong choice here
looks like a client that connects fine but gets empty answers.

---

## Troubleshooting

**Client won't connect / `404` "MCP server is not available."**
Check **Enabled** on the admin page — that is by far the most common cause.

**Client connects, but the assistant says it has no OpenProject capabilities.**
Different problem: the server is on but every tool is unticked, so it advertises an
empty tool list and returns `200`. Re-enable at least the tools you need under
**Tools** on the admin page.

**`401 Unauthorized`.**
The token is wrong, revoked, expired, or lacks the `mcp` scope. Re-check the Basic
auth username is the literal string `apikey` and not your login name. Test the
token with the `curl` command in [Verify end-to-end](#verify-end-to-end) before
blaming the client.

**Assistant says it can't find a project you can definitely see.**
Confirm you are connected as the right account by asking "using OpenProject, who am
I?". A token belonging to a different or less-privileged user is the usual answer.

**Assistant reports fields as `customField7` instead of real names.**
It now has `search_custom_fields` to resolve those, and `search_work_packages`
explicitly tells it to. If it still shows raw identifiers, check that
**Search custom fields** is ticked on the admin page — and note that a custom field is
only visible to a user through the projects and work package types it is enabled on, so
an assistant connected as a restricted user may genuinely not be able to resolve one.

**Assistant only ever finds 40 of something.**
That is the per-call page limit, not the total. The paginated tools report a `total`
alongside the results, so ask the assistant how many matches there are in all and to
fetch the remaining pages. If it insists 40 is everything, it is ignoring
the `total` it was given — say the number back to it, or narrow the question.

**A create, edit or comment is refused.**
The assistant is told why, in the same words OpenProject uses in the interface, and nothing is
written. The usual causes:

- *"These attributes cannot be set through this tool: …"* — it sent something the tools do not
  support: an attachment, a watcher, the author, a change of project, a typo, or a whole copy of a
  work package it had read. Ask it to send only the attributes it wants to change.
- *"There is no type (or status, or priority) with ID …"* — it guessed an ID. Ask it to look the
  value up first (`list_types`, `list_statuses`, `list_priorities`).
- *"Information has been updated by at least one other user in the meantime."* — someone changed
  the work package since the assistant read it. Ask it to read it again and retry.
- *"You are not allowed to comment on this work package."*, or any permission message — your
  account lacks the permission, exactly as it would in the interface.
- *"Tool not found: …"* — an administrator has switched that tool off.

**Nothing above fits.**
Server-side failures are logged with `Unhandled exception occured during MCP
request`, so grep the OpenProject log for that string.

---

## Notes & limitations

- **Some fields cannot be set yet.** An assistant has no way to look up the options of a
  list-type custom field, such as Labels, so it cannot set them. A long-text custom field has to
  be sent as `{"raw": "..."}`, and the assistant is told so. A milestone's single `date` property
  is not supported.
- **Writes are limited and marked, not blocked.** Whoever holds a token can use these tools
  wherever their own permissions allow, so treat a token as you would a password. The
  marker is an audit trail, not a control: it shows afterwards what an assistant did and
  prevents nothing.
- **40 results per call, for the tools that paginate.** Eight tools do: work packages,
  projects, programs, portfolios, versions, users, custom fields and work package
  comments. Those cap at 40 and report a `total`, so an assistant can tell whether more
  pages exist and ask for page 2, 3 and so on. `list_work_package_relations` and
  `search_custom_field_items` are *not* paginated — they return everything they find,
  with a `total` matching. `current_user`, `list_statuses` and `list_types` return one
  whole document and have no page or total at all. Broad questions still cost several
  round trips.
- **Hierarchy custom field values need Enterprise.** `search_custom_field_items` works,
  but hierarchy custom fields can only be *created* with an Enterprise token
  (`custom_field_hierarchies` is a separate feature from MCP, and this build does not
  ungate it). On a Community instance the tool has nothing to return.
- **Two tools trim their responses; direct resource reads do not.**
  `search_work_packages` drops the rendered HTML twin of every formatted text field and
  the action links an assistant cannot act on, which cuts those responses by roughly 40%.
  `list_work_package_comments` does the same and also empties each activity's
  attribute-by-attribute diff. Every other tool returns its payload untrimmed, and
  reading a single work package as a *resource* returns the full payload too, because
  resources are served on a path the filtering does not cover.
- **One endpoint per instance.** No per-project enablement.
- **Versions:** work packages are matched on their single assigned version. Upstream
  is moving to multiple target versions per work package; that change conflicts with
  this build's Release/Sprint model and is deliberately not ported.
- **The marker says an assistant, not which one.** The token's user and the marker are the
  same whichever client wrote.
- **Notifications follow the UI.** An assignee, a watcher or a mentioned person is notified
  of an assistant's change as they would be of yours. An assistant looping over many work
  packages sends many notifications.
- **An assistant can see internal comments you can see.** It must not copy them into a
  public comment; the tool says so, but that is guidance, not something the server can
  enforce.

---

## Related

- [MCP Server (administration)](../system-admin-guide/integrations/mcp-server/README.md)
  — the administrator-facing reference.
- [mcp-upstream-backlog.md](../development/mcp-upstream-backlog.md) — what upstream
  has built that this build has not taken yet, and why.
