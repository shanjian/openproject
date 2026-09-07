---
sidebar_navigation:
  title: Labels
  priority: 595
description: Create and apply labels, shared across the instance or owned by a single project
keywords: labels, label prefix, project labels, taxonomy, custom field
---

# Labels

Labels are values of a list custom field — in most installations the field is simply called
**Labels** — that you attach to work packages to mark a theme, a workstream or a source.

They come in two tiers:

| | **Shared labels** | **Project labels** |
|---|---|---|
| Created by | a system administrator | a project administrator |
| Named | anything the naming pattern allows | must start with the project's own prefix |
| Applies in | every project | the owning project only |
| Managed under | *Administration → Custom fields* | *Project settings → Labels* |

The point of the split is that you do not have to ask an administrator for every new label.
If a label matters only to your project, you create it yourself.

## Applying a label

Pick labels from the field on the work package, the same way as any other list field.

Which labels you are offered depends on the project the work package is in: **the shared
labels, plus the labels that project owns.** Another project's labels are not offered,
because they are not applicable there.

Seeing is not the same as applying. If a work package already carries a label — because it
was created in a project that owns it, or moved — you continue to see that label on the
work package as long as you can read it. It stays in the picker for that record so it is not
silently dropped when you edit something else.

### Moving and copying

**Moving keeps the labels.** A work package that moves to another project carries its labels
with it, including one owned by the project it has left. Editing something else about it
afterwards does not silently drop them.

**Copying does not.** When a work package is copied into another project — or when a whole
project is copied — labels that do not apply in the target are left off the copy. The
original keeps everything it had.

What you cannot do is *add* a label that does not apply. Applying one to a work package in a
project that cannot use it is rejected: *"Labels: a label was applied that this project
cannot use."*

## Creating labels for your project

You need the **Manage project labels** permission. If you have it, *Project settings →
Labels* appears in the project's settings menu.

The screen shows three things per label field:

1. a box to create a new label, with your project's prefix already shown in the placeholder;
2. **Labels owned by this project** — each with an editable name and a delete link;
3. **Shared labels** — read-only, so you can see which names are already taken.

### Naming

Every label your project creates must begin with your project's **label prefix** followed by
a hyphen. If your project's prefix is `AT`, its labels look like:

```
AT-bounce
AT-bounce-handling
AT-Trafficking
AT-2fa
AT-Bounce_v2
```

The rule in full:

- the prefix, exactly as assigned to your project, then a hyphen;
- then a name of letters and digits, in any case;
- further words may be joined with `-` or `_`.

Rejected: a bare prefix (`AT-`), a dangling or doubled separator (`AT-bounce-`,
`AT--bounce`), spaces, and another project's prefix.

Your administrator may have set a **stricter** rule on top of this, in which case the screen
shows it in words above the input. An administrator's rule can only narrow what is allowed,
never widen it.

### Renaming

Edit the name in place and save. The prefix has to stay — you cannot rename `AT-bounce` to
`ADT-bounce` and take over another project's namespace.

A rename changes the label everywhere it is already applied. That is usually what you want:
the work packages carrying it keep carrying it, under the new name.

### Deleting

Deleting a label removes it from every work package that carries it, in the same operation.
There is no undo, and no report of which work packages were affected — so if the label is in
use and you only want to stop new uses of it, rename it rather than delete it.

You cannot delete a shared label from this screen. You cannot delete another project's label
at all.

## For administrators

### Turning the feature on

Three things have to be true before a project administrator can create anything.

**1. The field must accept project-owned values.**

Under *Administration → Custom fields*, open the label field and set:

| Setting | Value |
|---|---|
| **Allow project-owned values** | ticked |
| **Value naming pattern** | e.g. `\A[A-Z][A-Z0-9]{1,5}-[A-Za-z0-9]+([-_][A-Za-z0-9]+)*\z` |
| **Naming pattern description** | e.g. *Start with your project's prefix and a hyphen, then a name: AT-bounce.* |

These three settings appear only on a **work package** custom field of format **List**.

A naming pattern is required whenever project-owned values are allowed — the checkbox will
not save without one. Write the description too: without it, a rejected value is explained
with the raw regular expression, which is not something to show a project administrator.

Two things worth knowing about the pattern:

- **It governs both tiers.** Shared labels must match it as well.
- **It is checked when a value is created or renamed, never on unrelated saves.** Existing
  labels that do not match are not invalidated and stay applicable — they simply cannot be
  renamed until they conform.

**2. Each project needs a label prefix.**

Under *Administration → Projects → Label prefixes*. A prefix is two to six upper case
letters or digits, starting with a letter, and no two projects may share one. The screen
suggests one derived from the project identifier where that yields something legal —
`web-ext` suggests `WEBEXT` — and says so where it does not. A suggestion is only a
suggestion until you save it.

A project without a prefix cannot own labels. Its settings screen says so rather than
failing later.

**3. Roles need the permission.**

`manage_project_labels` is granted by migration to every role that already holds
`edit_project`, so on an existing installation the people who administer a project get it
without any action. You can add or remove it per role under *Administration → Roles and
permissions*.

There is a script that does steps 1 and 2 and reports on step 3:

```bash
bundle exec rails runner script/enable_project_labels.rb          # dry run, writes nothing
APPLY=1 bundle exec rails runner script/enable_project_labels.rb  # write
```

It is re-runnable, it never invents a prefix it cannot derive, and it lists the existing
labels that would not match your new pattern.

### Creating shared labels

*Administration → Custom fields → the label field*. Values added there have no owning
project and are applicable everywhere. They are subject to the naming pattern like any other
value, but not to any project's prefix.

### Changing a prefix

Changing a project's prefix **renames every label that project owns** to match, in one
transaction. If any one of those renames would fail — because it would collide with an
existing name, for instance — the prefix change is refused and the screen names the label
that blocked it.

A prefix cannot be cleared while the project still owns labels: *"cannot be cleared while
this project owns 4 label(s). Delete or promote them first."* Clearing it would leave those
labels carrying a prefix the project no longer has, and free the prefix for another project.

### Deleting a project

Labels the project owns are dealt with automatically:

- a label **nothing else references** is deleted along with its stored values;
- a label **still carried by a work package in another project** is promoted to a shared
  label, so nothing loses data.

There is no way to promote a label by hand from the interface. If you need to, a system
administrator can do it from the Rails console:

```ruby
CustomOption.find(id).update!(project_id: nil)
```

### Turning the feature off

Untick **Allow project-owned values** and the field stops accepting new project labels. This
is **refused while any project-owned values still exist** — *"cannot be turned off while 12
project-owned value(s) exist. Delete or promote them first."* — because those labels would
otherwise stay attached to their projects while becoming applicable everywhere, and the
screen that could remove them would be hidden.

## When something is rejected

| Message | What it means |
|---|---|
| *Project-owned labels are not enabled on any field.* | Step 1 above has not been done. An administrator ticks **Allow project-owned values** on the label field. |
| *This project has no label prefix, so it cannot own labels yet.* | Step 2 above. An administrator assigns one under *Administration → Projects → Label prefixes*. |
| *must start with this project's label prefix, AT-.* | You typed a name without the prefix, or with someone else's. |
| *must look like PREFIX-name, e.g. AT-bounce.* | The prefix is right but the rest is not a legal name — a bare prefix, a trailing separator, or a space. |
| *Labels: a label was applied that this project cannot use.* | You tried to add a label owned by a different project. Only shared labels and this project's own can be applied here. |
| *is already used by a label shared by all projects.* | A shared label has that name. Two labels reading the same in the same picker would be ambiguous, so use a different name — or ask an administrator whether the shared one already covers your case. |
| *is already used by a label owned by a project.* | The reverse, seen by an administrator creating a shared label. Rename or promote the project's label first. |
| *cannot be enabled until a label naming pattern is set.* | **Allow project-owned values** needs **Value naming pattern** filled in. |
| *You are not allowed to manage labels in this project.* | Your role lacks `manage_project_labels`. |
