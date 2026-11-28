# Proposal: Clearer work package dates — "Scheduled dates" vs "Completed date"

## 1. Problem we have today

Every work package has two built-in dates: a **start** date and a **finish** date. Both are **planned / scheduled** dates — when work is *supposed* to start and *supposed* to finish. They drive the Gantt chart, scheduling, and dependencies. **Neither records when work actually finished.**

This causes several problems:

- In the form configuration, the two planned dates are bundled into a single field labeled just **"Date"** — vague, and it doesn't convey that this is the *plan*.
- The finish date is labeled **"Finish date"**, which is ambiguous — it reads like it might mean "the day it was finished," when it actually means "the day it's due."
- OpenProject has **no built-in field for the actual completion date** (the day a ticket was marked Done). To work around this we added custom fields ("Start date", "End date"), but they **duplicate** the built-in planned dates and have to be filled in **manually**, so they're often missing or wrong.
- We depend on completion data for reporting — e.g. *"how many story points did each person complete in a sprint?"* That requires a reliable, filterable **actual completion date**, which we don't have today.

## 2. Proposed solution

Make the **planned vs. actual** distinction explicit, and automate the actual completion date.

**A. Rename the planned dates for clarity**
- **"Date" → "Scheduled dates"** — the field holding the planned start and due dates.
- **"Finish date" → "Due date"** — clearer (the planned deadline), and consistent with "Scheduled dates".
- These are **label changes only.** No data is moved or deleted; existing filters, saved views, and integrations keep working.

**B. Introduce a real completion date**
- Rename the existing **"End date"** custom field to **"Completed date"** (a rename — existing values are kept).
- **Auto-fill** "Completed date" with today's date when a ticket moves to status **"Done"**. Users can still edit it manually.

**C. Remove redundancy**
- **Delete the custom "Start date" field** — the built-in "Scheduled dates" already covers the planned start.

The end state: every work package clearly has **Scheduled dates** (the plan) and **Completed date** (the day it was actually finished, filled in automatically).

## 3. What you will expect

**Benefits**
- Reliable reporting: filter by **Completed date** range, group by assignee, sum story points → each person's completed work in a sprint.
- No more confusion between planned dates and the actual finish.
- Less manual entry — the completion date fills itself.

**What changes day-to-day**
- The field shown as **"Date"** now reads **"Scheduled dates"**, and **"Finish date"** now reads **"Due date"**. Same dates, new names — existing filters, views, exports, and integrations are unaffected (only the on-screen labels change).
- When you set a ticket to **Done**, its **Completed date** is set to today automatically. If you re-open and re-complete a ticket, the Completed date updates to the new completion day.
- Only the status literally named **"Done"** triggers auto-fill. Other closed statuses (e.g. "Closed", "Rejected") will **not** set it. *(If the "Done" status is ever renamed, auto-fill stops until reconfigured.)*
- The custom **"Start date"** field will be removed. Any data in it will be lost and any view/filter using it will need updating — **please speak up now if you rely on it.**

**Things to be aware of**
- **History is not auto-backfilled.** Tickets completed *before* this change will have an empty Completed date. If we need accurate historical reports, we'll run a one-time backfill from the change history (the day each ticket first became "Done").
- **Completed date ≠ Due date.** A ticket finished late keeps its planned Due date; only Completed date reflects the real finish day — that's the point: you can now compare *planned vs. actual*.

**Open question for reviewers**
- Should "Completed date" be **overwritten** every time a ticket re-enters "Done" (always reflects the latest completion), or set **only once** (first completion)? Current plan: overwrite on each transition to Done.
