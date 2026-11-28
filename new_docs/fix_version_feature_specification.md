# Feature Specification: Release Version Control System ("Fix Version")

## 1. Feature Overview & Purpose

### 1.1 Executive Summary
In agile software development and project management, tracking **how** work is completed (e.g., Sprints, tasks, workflows) is distinct from tracking **where** and **when** that work is delivered to end-users. The **Fix Version** feature serves as the core deployment container in the ticketing system. It bridges day-to-day issue resolution with product release management, providing teams with a structured mechanism to plan, track, audit, and execute software shipments.

### 1.2 Core Objectives
* **Release Scoping:** Group heterogeneous issue types (Bugs, Features, Tasks) into a single logical deployment package.
* **Timeline Accountability:** Establish definitive start dates, target release dates, and actual completion dates for software iterations.
* **Quality & Readiness Auditing:** Provide real-time visibility into the development and testing status of all issues assigned to a specific release target.
* **Historical Governance:** Preserve a permanent audit trail of what code/features were deployed in which historical version block.

---

## 2. Functional Architecture & Data Model

### 2.1 Entity Relationship Diagram (Conceptual)
```
+-----------------------------------+
|             PROJECT               |
+-----------------------------------+
                 | 1
                 |
                 | 0..*
+-----------------------------------+
|             VERSION               |
+-----------------------------------+
                 | 1
                 |
                 | 0..*
+-----------------------------------+
|       VERSION_ISSUE_MAPPING       | (Join Table for Many-to-Many)
+-----------------------------------+
                 | 0..*
                 |
                 | 1
+-----------------------------------+
|              ISSUE                |
+-----------------------------------+
```

### 2.2 Version Entity Schema (Database Fields)
Each version record must contain the following attributes:

| Field Name | Data Type | UI Field Label | Constraints / Validation |
| :--- | :--- | :--- | :--- |
| `id` | UUID / BigInt | — | Primary Key, Auto-generated |
| `project_id` | UUID / BigInt | — | Foreign Key linking to `PROJECT.id` |
| `name` | String (255) | Version name | Required. Must be unique within the scope of the project. Strip leading/trailing whitespaces. |
| `description` | Text | Description | Optional. Rich text or plain string up to 4000 characters. |
| `status` | Enum | Status | Must be one of: `UNRELEASED`, `RELEASED`, `ARCHIVED`. Default: `UNRELEASED`. |
| `start_date` | Date | Start date | Optional. Must be less than or equal to `release_date`. |
| `release_date` | Date | Release date | Optional. Target deployment date. |
| `actual_release_date`| Date | — | System-populated timestamp when status changes to `RELEASED`. |
| `created_at` | Timestamp | — | System-generated creation time. |
| `updated_at` | Timestamp | — | System-generated update time. |

### 2.3 The Field Type: `Fix Version/s`
* **Data Structure:** Many-to-Many relationship model. An issue can be assigned to **zero, one, or multiple** Fix Versions (e.g., a critical bug fix applied to hotfix patch `v1.0.1` and main branch `v1.1.0`).
* **Behavioral Distinction from "Affects Version/s":**
    * `Affects Version/s`: Historical capture. Indicates the environment/version where a defect was *discovered*.
    * `Fix Version/s`: Forward-looking capture. Indicates the targeted milestone where the resolution or feature will be *deployed*.

---

## 3. UI/UX Workflow Specifications

### 3.1 Version Management Dashboard (Project Level)
Accessible via **Project Settings > Releases** or a dedicated **Releases** tab in the project sidebar.

#### 3.1.1 Create Version Form
A modal or inline form containing:
* `Name` (Input Text, Mandatory)
* `Start Date` (Date Picker, Optional)
* `Release Date` (Date Picker, Optional)
* `Description` (Text Area, Optional)
* **Action Buttons:** `Save` (disabled if `Name` is empty or matches an existing non-deleted version in the project), `Cancel`.

#### 3.1.2 Version Registry Table
Displays all versions created in the project, separated by status tabs (`All`, `Unreleased`, `Released`, `Archived`). Columns include:
* Drag handle (for manual reordering, which influences default dropdown sorting).
* Version Name (clickable, links to the **Fix Version Page**).
* Status Badge (styled distinctly per status color scheme).
* Progress Bar (Visual distribution of underlying issues: Completed, In Progress, Unstarted).
* Start / Release Dates.
* Actions Menu (`...` dropdown):
    * `Edit` (Opens modification modal).
    * `Release` (Only if status is `UNRELEASED`).
    * `Archive` / `Unarchive`.
    * `Delete`.

---

### 3.2 The Fix Version Page (Release Hub View)
Triggered by selecting a specific version name. This page acts as the mission control panel for that release.

```
+-----------------------------------------------------------------------------------------+
| [Project] / Releases / v2.4.0                                        [ Release ] [ ... ]|
| Description: Q3 Core Payment Engine Upgrades                                             |
| Status: UNRELEASED  |  Start: 2026-06-01  |  Target: 2026-07-15                         |
+-----------------------------------------------------------------------------------------+
| PROGRESS: [██████████████████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░] 45% Done              |
|           (25 Done / 15 In Progress / 15 To Do)                                         |
+-----------------------------------------------------------------------------------------+
|  [ Issues ]   [ Warnings (3) ]   [ Release Notes Preview ]                               |
+-----------------------------------------------------------------------------------------+
|  STATUS     ISSUE KEY    SUMMARY                         ASSIGNEE       DEVELOPMENT     |
|  [Done]     PAY-412      Implement Stripe Elements V3    Sarah K.       [PR Merged]     |
|  [In Prog]  PAY-501      Fix race condition on webhook   Alex M.        [1 Open PR]     |
|  [To Do]    PAY-555      Update documentation ledger     Unassigned     --              |
+-----------------------------------------------------------------------------------------+
```

#### 3.2.1 Component Elements
1.  **Header Meta Block:** Displays Name, Description, Status tag, and configured dates.
2.  **Aggregated Status Bar:**
    * Calculates completion metrics based on *Issue Count* or *Story Point Weight*.
    * Color segments: Green (`DONE` status category), Blue (`IN_PROGRESS` status category), Grey (`TO_DO` status category).
3.  **Issue Data Table:** Enumerates all linked tickets. Columns are sorting-enabled and support quick filtering by assignee, issue type, and resolution status.
4.  **Automated Quality Warnings Tab:**
    * Evaluates background integrity flags to surface delivery risks.
    * *Rule 1: Unresolved Development:* Flags any issue in the version marked as `Done` in the tracking board but possessing an open Git Pull Request (`state == OPEN`).
    * *Rule 2: Orphaned Tickets:* Flags any ticket belonging to the version that does not have an assignee or is missing from the active development sprint cycle.
5.  **Release Notes Engine:** Dynamically renders an exportable Markdown text block aggregating all tickets where `Fix Version == [Current Version]` and `Status Category == DONE`, grouped cleanly by Issue Type (e.g., Features, Bug Fixes).

---

### 3.3 Linking Mechanisms (Issue Assignment)
Users can establish links via three discrete interfaces:

1.  **Single Issue View Details Panel:**
    * A dropdown control rendering all `UNRELEASED` versions matching the current `project_id`.
    * Asynchronous write execution upon selection change, generating an activity stream log item: `[User] updated Fix Version/s to v2.4.0`.
2.  **Backlog Sidebar Panel Integration:**
    * An expandable vertical pane containing the version registry.
    * Supports UI Drag-and-Drop capability: Selecting one or multiple issues from the main backlog pool and dropping them onto the Version container UI block automatically updates their `Fix Version/s` property.
3.  **Bulk Edit Action Processor:**
    * Multi-select search interface supporting a secondary mutation modal.
    * Provides explicit selection options: `Append to existing versions`, `Replace all current versions`, or `Clear field value`.

---

## 4. Advanced Logic & Business Rules

Implementing this subsystem requires strict adherence to explicit systemic boundary constraints:

### 4.1 Project Isolation Boundary
* Versions are completely compartmentalized inside their respective `project_id`. A version named `v1.0.0` inside Project A possesses a unique database entity identity independent of an identical string token `v1.0.0` generated inside Project B.
* *Cross-Project Epics Exception:* If an issue entity from Project Alpha acts as a parent item (Epic/Initiative) to child tickets living in Project Beta, the parent issue's `Fix Version` field only lists options native to Project Alpha. It does not automatically synchronize or display cross-project child version milestones.

### 4.2 Inheritance Hierarchies
* **Sub-task Rule:** Sub-tasks are treated as atomic units of execution rather than distinct product increments. They **do not** implicitly inherit the `Fix Version` of their parent issue.
    * *System Design Choice:* To preserve flexibility, sub-task versions remain unassigned unless explicitly injected manually, or synchronized via an administrative global trigger system automation rule.

### 4.3 Lifecycle Transitions & Mutation Rules

```
                  +-------------------+
                  |    UNRELEASED     |
                  +-------------------+
                    /                      Click "Release"               Click "Archive"
                  /                                    v                     v
    +-----------------+           +-----------------+
    |    RELEASED     |           |    ARCHIVED     |
    +-----------------+           +-----------------+
             \                             /
        Click "Archive"               Click "Unarchive"
               \                         /
                v                       v
              +---------------------------+
              |     ARCHIVED RELEASED     | (State variation)
              +---------------------------+
```

#### 4.3.1 Executing the "Release" Action
When an authorized user clicks the **Release** trigger option on an unreleased version:
1.  **Incomplete Issue Integrity Evaluation Check:** The system scans for issues where `Fix Version == Target` and `Status Category != DONE`.
2.  **Resolution Dialog Prompt:** If incomplete tickets exist, the user must select an explicit mitigation strategy through an interactive dialog prompt:
    * *Option A (Roll Forward):* Bulk-migrate all remaining incomplete tickets to a different active unreleased version dropdown selection target.
    * *Option B (De-couple):* Clear the `Fix Version/s` mapping link value from incomplete tickets entirely, returning them clean into the general project product backlog bucket.
    * *Option C (Ignore/Force):* Retain the version definition on the incomplete issues, forcing them to remain mapped to the frozen closed release container.
3.  **State Execution:** Mutates version status enum to `RELEASED`. Populates `actual_release_date` with current runtime machine timestamp. Hides the version entry from everyday issue screening assignment choice views while preserving historical queryability.

#### 4.3.2 Executing the "Archive" Action
* Marks version flag field as `ARCHIVED`.
* Completely strips the target version selection visibility entry from *all* issue update screens, ticket creation templates, and drag-and-drop workflow panels across the app instance ecosystem.
* **Safety Isolation Principle:** All historical maps are strictly locked and retained intact. Pre-existing closed issue logs mapping to archived milestones remain unmuted.

#### 4.3.3 Executing the "Delete" Action
When a project administrator requests full object entity deletion:
1.  The system halts execution and prompts a critical destructive warning check modal if the target container maps to active issue rows.
2.  The administrator must select a fallback route:
    * Remove reference entirely across all existing database issue rows.
    * Swap out the targeting reference keys across all issues, redirecting them entirely to an alternate active version identifier block.

---

## 5. API & Integration Specifications

### 5.1 REST API Endpoints

#### 1. Create a Version
* **HTTP Method & Path:** `POST /api/v1/projects/{project_id}/versions`
* **Payload (JSON):**
    ```json
    {
      "name": "v1.4.0-beta",
      "description": "Core routing module upgrade",
      "startDate": "2026-06-01",
      "releaseDate": "2026-06-30"
    }
    ```
* **Response Codes:** `201 Created` (Success), `400 Bad Request` (Missing name, invalid dates), `409 Conflict` (Version name already exists in project).

#### 2. Get Project Versions
* **HTTP Method & Path:** `GET /api/v1/projects/{project_id}/versions?status=unreleased`
* **Response Codes:** `200 OK` (Returns an array of version objects matching query filter parameter).

#### 3. Update / Release / Archive a Version
* **HTTP Method & Path:** `PUT /api/v1/versions/{version_id}`
* **Payload (JSON):**
    ```json
    {
      "status": "RELEASED",
      "moveIncompleteIssuesTo": "uuid-next-milestone-version"
    }
    ```
* **Response Codes:** `200 OK`, `404 Not Found`.

### 5.2 Query Engine Integration (Advanced Search Syntax Example)
The global system search tool requires query token handlers explicitly tailored for this property type:
* `fixVersion = "v2.0"` : Extracts tickets explicitly assigned to version name literal string value matching "v2.0".
* `fixVersion in unreleasedVersions()` : Dynamically evaluates all issues tied to versions configured with state `UNRELEASED`.
* `fixVersion is empty` : Isolates orphaned issues lacking scheduled deployment metadata containers.
