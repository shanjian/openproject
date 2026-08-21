# Connect an AI assistant to OpenProject (MCP)

This build ships an **MCP server**: a single endpoint that lets an AI assistant —
Claude Code, Claude Desktop, or any other MCP client — read data out of this
OpenProject instance and use it when answering you.

Ask "what's still open in the Website Redesign project?" and the assistant queries
OpenProject directly instead of guessing or asking you to paste anything in.

Two things are worth knowing up front:

- **It only reads.** Nothing an assistant does through MCP can create, change, or
  delete anything in OpenProject. See [What it can and can't do](#what-it-can-and-cant-do).
- **It sees exactly what you see.** Every request runs as the user whose token the
  client holds, through the same permission checks as the rest of OpenProject. An
  assistant cannot surface a project you have no access to.

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

**It can read**, through nine tools:

| Tool | Answers |
|---|---|
| `search_work_packages` | Work packages by assignee, author, ID, project, status, type, version, or partial subject |
| `search_projects` | Projects by name, identifier, or status |
| `search_programs` | Programs (the project level above projects) |
| `search_portfolios` | Portfolios (the level above programs) |
| `search_versions` | Versions by name |
| `search_users` | Users by name |
| `list_statuses` | Every work package status on the instance |
| `list_types` | Every work package type on the instance |
| `current_user` | Who the token belongs to |

Alongside these it exposes **resources** — direct lookups of a single project,
work package, user, version, type, or status by ID, which a client can fetch
without a search.

**It cannot write.** There is no tool to create, edit, comment on, or delete
anything, and no way to configure one. Assistant-suggested changes still have to
be made by a person in the UI.

**It cannot exceed your permissions.** Every query is scoped to what the token's
user can see. Two people connecting the same assistant to the same instance get
different answers, correctly.

> Upstream has begun building write tools — creating work packages, comments, and
> relations. They are deliberately **not** in this build. See
> [mcp-upstream-backlog.md](../development/mcp-upstream-backlog.md) for the open
> questions, notably that agent-authored comments would notify subscribers and
> journals would not distinguish agent edits from human ones.

---

## Tuning what the assistant sees

Everything below is on the admin page, under **Tools** and **Resources**, and takes
effect on the next client connection.

**Turn individual tools off.** Unticking a tool removes it from the server
entirely — clients stop being offered it. Useful for narrowing what an assistant
can reach without switching MCP off wholesale.

**Rename tools to match your vocabulary.** Each tool's title and description are
editable, and the assistant reads both when deciding what to call. If your team
says "work items" rather than "work packages", renaming *Search work packages* to
*Search work items* measurably improves the assistant's choices — it gives the
model an explicit cue that the two terms mean the same thing.

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
Expected in this build — the tool that resolves custom field names is not ported
yet. Tracked as item 2 in
[mcp-upstream-backlog.md](../development/mcp-upstream-backlog.md).

**Assistant only ever finds 40 of something.**
That is the per-call page limit, not the total. Every search response reports a
`total` alongside the results, so ask the assistant how many matches there are in
all and to fetch the remaining pages. If it insists 40 is everything, it is ignoring
the `total` it was given — say the number back to it, or narrow the question.

**Nothing above fits.**
Server-side failures are logged with `Unhandled exception occured during MCP
request`, so grep the OpenProject log for that string.

---

## Notes & limitations

- **Read-only.** By design in this build.
- **40 results per call.** Every search caps there, and a client requests page 2, 3
  and so on to get the rest. Each response also reports `total`, the full number of
  matches, so an assistant can tell whether more pages exist rather than guessing.
  Broad questions still cost several round trips.
- **Custom field names are not resolved.** Reported as `customFieldN`.
- **Responses are verbose.** Work package payloads currently include rendered HTML
  alongside the raw text plus a large block of internal links, which consumes the
  assistant's context for no benefit. Upstream's fix is item 1 in the backlog.
- **One endpoint per instance.** No per-project enablement.
- **Versions:** work packages are matched on their single assigned version. Upstream
  is moving to multiple target versions per work package; that change conflicts with
  this build's Release/Sprint model and is deliberately not ported.
- **No agent audit trail.** Since MCP cannot write, nothing needs one yet — but it
  is the open question blocking write tools.

---

## Related

- [MCP Server (administration)](../system-admin-guide/integrations/mcp-server/README.md)
  — the administrator-facing reference.
- [mcp-upstream-backlog.md](../development/mcp-upstream-backlog.md) — what upstream
  has built that this build has not taken yet, and why.
