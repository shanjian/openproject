# Department and Team OKR Process

## Purpose

This document explains how departments and teams create, maintain, and review OKRs within OpenProject.

For OKR principles, definitions, and scoring methodology, see:

**Company OKR Framework**

# OpenProject Structure

All OKRs are managed within a single project:

```text
Company OKRs
```

We do not create separate OpenProject projects for each department.

Benefits:

- Company-wide visibility
- Simpler reporting
- Better cross-functional collaboration
- Easier executive review

Quarterly OKR cycles are managed using OpenProject **Versions**.

Example:

```text
2026 Q3
2026 Q4
2027 Q1
```

# Organizational Model

## Leadership Team

Leadership creates:

- Strategic Initiatives
- Company-level priorities

Examples:

- Subscription Growth
- Audience Growth
- Product Excellence

These become the top-level structure for quarterly planning.

## Departments

Departments create Objectives under Strategic Initiatives.

Example:

```text
Strategic Initiative
└── Subscription Growth

    Objective (Marketing)
    Increase qualified subscriber acquisition

    Objective (Product)
    Improve subscription conversion

    Objective (Editorial)
    Increase subscriber engagement
```

Each department should generally maintain:

- 3–5 Objectives per quarter

Each Objective must be assigned to the appropriate **Organizational Unit**.

Example:

```text
Organizational Unit: Marketing
```

## Teams

Teams create Key Results and supporting Tasks that contribute to department Objectives.

Example:

```text
Objective
Increase subscriber engagement

    Key Result
    Increase newsletter open rate from 30% to 40%

        Task
        Improve newsletter design

        Task
        Implement segmentation

        Task
        Test subject lines
```

A Key Result should be assigned to the Organizational Unit that owns the result.

Example:

```text
Organizational Unit: Marketing / Audience Development
```

Tasks may be created under a Key Result when the work is managed directly within the Company OKRs project.

If execution work is already managed in another OpenProject project, the existing work should be linked to the Key Result rather than duplicated.

# Required Fields

## Objective

Every Objective must contain:

- Objective name
- Accountable owner
- Organizational Unit
- Current quarter / Version
- OKR Health
- Confidence
- Parent Strategic Initiative
- Description of the intended outcome

Recommended:

- Risks or assumptions
- Supporting comments or context

Example:

```text
Objective:
Increase subscriber retention

Accountable:
Director of Retention

Organizational Unit:
Marketing / Retention

Version:
2026 Q3

OKR Health:
On Track

Confidence:
80%
```

## Key Result

Every Key Result must contain:

- Key Result name
- Accountable owner
- Organizational Unit
- Current quarter / Version
- Baseline
- Target
- Current Metric
- Progress %
- OKR Health
- Confidence
- Parent Objective

Recommended:

- Metric Unit
- Metric Source
- Last Check-in
- Notes or comments explaining material changes

Example:

```text
Key Result:
Increase newsletter open rate from 30% to 40%

Accountable:
Audience Development Manager

Organizational Unit:
Marketing / Audience Development

Version:
2026 Q3

Baseline:
30%

Target:
40%

Current Metric:
36%

Progress:
60%

OKR Health:
On Track

Confidence:
75%
```

Progress should be based on achievement of the Key Result metric, not completion of supporting Tasks.

# Quarterly Planning Process

## Step 1

Leadership creates or confirms Strategic Initiatives.

Strategic Initiatives provide the company-level direction for planning.

## Step 2

Departments create Objectives.

Each Objective must:

- Support a Strategic Initiative
- Have a single owner
- Be assigned to an Organizational Unit
- Be assigned to the current quarter
- Describe an outcome rather than an activity

## Step 3

Teams create Key Results.

Each Key Result must:

- Support an Objective
- Be measurable
- Include a baseline
- Include a target
- Have a single owner
- Be assigned to an Organizational Unit
- Be assigned to the current quarter

## Step 4

Teams create supporting Tasks when needed.

Tasks should normally be created under a Key Result.

Tasks represent work performed to influence the Key Result.

Completing the Tasks does not automatically mean the Key Result has been achieved.

# Weekly Update Process

All active Objectives and Key Results should be reviewed weekly.

## Objective Owners

Update:

- Confidence
- OKR Health
- Risks
- Comments

Objective owners should also review the progress of the Key Results beneath their Objective.

## Key Result Owners

Update:

- Current Metric
- Progress %
- Confidence
- OKR Health
- Last Check-in
- Comments when there is a material change

Example:

```text
Key Result:
Increase newsletter open rate from 30% to 40%

Baseline:
30%

Target:
40%

Current Metric:
36%

Progress:
60%

Confidence:
75%

OKR Health:
On Track

Last Check-in:
2026-08-07

Comment:
Open rate improved following audience segmentation.
The next test will focus on subject-line personalization.
```

# Monthly Department Review

Department leaders review:

- Objective status
- Key Result progress
- OKR Health
- Risks
- Dependencies
- Resource needs
- Items that have not been updated recently

Questions:

1. Are we on track?
2. What is blocked?
3. What support is needed?
4. What should change?

Department reviews should focus primarily on **At Risk** and **Off Track** OKRs rather than spending equal time on every item.

# Executive Review

Leadership reviews all active Objectives monthly.

Recommended views:

### Company Objectives

```text
Type = Objective
OKR Level = Company
Version = Current Quarter
```

### Department Objectives

Example:

```text
Type = Objective
Organizational Unit = Marketing
Version = Current Quarter
```

```text
Type = Objective
Organizational Unit = Editorial
Version = Current Quarter
```

```text
Type = Objective
Organizational Unit = Technology
Version = Current Quarter
```

### At-Risk OKRs

```text
Version = Current Quarter
OKR Health = At Risk OR Off Track
```

### Key Results

```text
Type = Key Result
Version = Current Quarter
```

Recommended columns:

```text
Subject
Accountable
Organizational Unit
Baseline
Target
Current Metric
Progress %
Confidence
OKR Health
Last Check-in
```

# End-of-Quarter Process

1. Update the final Current Metric
2. Finalize Key Result progress
3. Score Key Results
4. Review Objective outcomes
5. Capture lessons learned
6. Set finished items to **Completed**
7. Identify any OKRs that continue and set them to **Moved to Next Quarter**
8. Create the next quarter's OKRs
9. Close the completed quarterly Version after review

If an unfinished OKR continues into the next quarter, preserve the historical record of the original quarter and create or copy the OKR into the next quarter rather than simply changing its original quarter.

# OpenProject Status and OKR Health

OpenProject Status and OKR Health serve different purposes.

Use **Status** to describe the lifecycle of the OKR item itself:

```text
Draft                    Being written during quarterly planning
Committed                Reviewed and committed for the quarter
Completed                Quarter ended; the item has been scored and completed
Moved to Next Quarter    Carried over; a copy continues in the next quarter
```

Draft is the initial status of newly created and imported items.

Execution progress of Objectives and Key Results is **not** tracked through Status.
Use OKR Health, Progress %, and Confidence for that.

OKR Tasks use the same four statuses. Execution progress of a Key Result is
visible through its metric fields, not through additional task statuses.

Use **OKR Health** to describe the likelihood of achieving the intended result:

```text
Not Started
On Track
At Risk
Off Track
```

Example:

```text
Status: Committed
OKR Health: At Risk
```

# Configuring the Statuses

Statuses and workflows are administered globally by an OpenProject administrator.

## Step 1 — Create the statuses

**Administration → Work packages → Status**

- Create **Draft**. Check **Default**, so new items start as Draft.
- Create **Committed**.
- Create **Completed**. Check **Closed**.
- Create **Moved to Next Quarter**. Check **Closed**.

Note: the default status applies to the whole OpenProject instance, not only to
OKR types. Every newly created work package in every project will start as Draft.
(Until this change, the instance default was "Needs Review", which is why newly
imported OKR items appeared with that status.)

## Step 2 — Allow the transitions

**Administration → Work packages → Workflow**

For each OKR type (Strategic Initiative, Objective, Key Result, OKR Task) and each
role that manages OKRs:

1. Select the type and the role, uncheck "Only display statuses that are used by
   this type", and click **Edit**.
2. Allow these transitions:

```text
Draft      → Committed
Committed  → Draft, Completed, Moved to Next Quarter
```

A status is only offered for a type when the type's workflow uses it, and the
status dropdown of a new work package only offers the default status plus the
statuses reachable from it. The workflow above is what makes the whole
lifecycle selectable.

The **Copy** function on the workflow page copies a finished workflow to the
other OKR types and roles.

## Step 3 — Status of imported OKRs

The markdown import automatically gives every item the **Draft** status, as
long as a status with that exact name exists and is part of the item type's
workflow. No front matter is needed for this.

A document can still choose a different status explicitly — once in the front
matter (inherited by every item):

```text
---
Version: 2026 Q3
Status: Committed
---
```

or per item, with its own attribute bullet:

```text
- Status: Committed
```

If neither Draft nor an explicit status applies (for example the Draft status
has not been created yet, or it is not in the type's workflow), the item falls
back to the instance default status.

# Duplicate Protection on Import

The import skips any item whose **Subject and Organizational Unit** (compared
case-insensitively on the subject) match:

- an existing work package in the project, or
- an earlier item in the same document.

Skipped items are listed as warnings on the preview and on the import result
page — they do not block the import. Children of a skipped item are attached
to the already-existing work package instead, so re-importing a corrected or
extended document adds only what is new.

Because the quarter (Version) is *not* part of the duplicate check, an OKR
that continues into the next quarter must be given a distinguishable subject
or be created as a copy manually, per the end-of-quarter process.

# Golden Rule

Every Task should support a Key Result.

Every Key Result should support an Objective.

Every Objective should support a Strategic Initiative.

Every Objective and Key Result should have a clearly defined Organizational Unit and Accountable owner.

If work cannot be connected to a Strategic Initiative, its priority should be reconsidered.