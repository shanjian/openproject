# OpenProject Functionality and Usage

## Presentation draft (Markdown outline)

**Purpose:** Overview presentation explaining what OpenProject is, what it can do, and how teams typically use it in practice.  
**Audience:** Project managers, team leads, PMO, engineering/product teams, and administrators evaluating or onboarding OpenProject (with prior Jira experience).  
**Format:** Slide-ready markdown outline for later conversion into presentation slides.

---

## Slide 1 — Presentation goals

## What this presentation covers

- What OpenProject is and where it fits
- Core functionality and main modules
- Jira-to-OpenProject concept mapping for fast onboarding
- Typical user roles and usage patterns
- Administration, customization, and integrations

**Presenter note:**
Set expectations: this is an overview deck, not detailed system training.
Mention that each core concept will be anchored to Jira terminology.

---

## Slide 2 — Why we choose OpenProject

## Common business needs it addresses

- Have decent functionality as a project collaboration tool.
- Open source, we can customize to do whatever we need.
- One shared view of project work and status

---

## Slide 3 — Functional map

## OpenProject capability areas

### 1. Planning and scheduling
- Projects and subprojects
- Work packages
- Milestones
- Gantt charts
- Roadmaps

### 2. Agile and execution management
- Boards / Kanban / Scrum-style workflows
- Backlogs and sprint-style planning
- Team planner

### 3. Collaboration
- Meetings
- Comments and activity history
- Documents
- Notifications / subscriptions

### 4. Control and reporting
- Status tracking
- Time tracking
- Cost reporting and budgeting
- Filters, queries, exports, dashboards

### 5. Platform and extensibility
- Roles and permissions
- Workflows and custom fields
- API and integrations

### Jira concept quick-reference
- Jira Project -> OpenProject Project
- Jira Issue -> OpenProject Work package
- Jira Issue Type -> OpenProject Type
- Jira Sub-task -> OpenProject Child work package
- Jira Workflow/Status -> OpenProject Workflow/Status
- Jira Board (Scrum/Kanban) -> OpenProject Board
- Jira JQL + saved filters -> OpenProject Queries/filters
- Jira Time tracking/apps -> OpenProject Time and cost reporting

---

## Slide 4 — Core concept: projects

## Projects are the main organizing structure

- Work in OpenProject is grouped into **projects**
- Closest Jira concept: **Project**
- Projects can represent initiatives, products, departments, programs, or client engagements
- Each project can have:
  - members
  - modules enabled/disabled
  - custom settings
  - project-specific work package types, categories, versions, and workflows

**Why it matters:**
Projects create a controlled workspace for planning, collaboration, and reporting.

---

## Slide 5 — Core concept: work packages

## Work packages = the central unit of work

- Work packages are the main records used to manage work
- Closest Jira concept: **Issue**
- They can represent:
  - tasks
  - user stories
  - bugs
  - features
  - risks
  - change requests
  - milestones or deliverables
- Typical fields include:
  - subject
  - type
  - status
  - assignee
  - priority
  - start/due dates
  - estimated time
  - remaining work
  - custom fields

**Key message:**
Most planning, execution, and reporting in OpenProject revolves around work packages.

**Presenter note (for Jira users):**
Use "work package = Jira issue" as the baseline mental model for the rest of the deck.

---

## Slide 6 — Structuring work packages

## How work is organized

- Hierarchies: parent/child work packages
- Closest Jira concept: Epic/Story/Sub-task hierarchy (implemented through parent/child relations and types)
- Relations: precedes, follows, relates to, duplicates, blocks, etc.
- Versions and milestones for release or phase planning
- Categories and custom fields for business-specific structure
- Saved filters and queries for focused views

**Presenter note:**
Explain that OpenProject supports both simple task lists and more structured project breakdowns.

---

## Slide 7 — Planning with Gantt charts

## Timeline and dependency management

- Gantt charts visualize tasks over time
- Useful for:
  - phase planning
  - milestone planning
  - dependency mapping
  - critical delivery alignment
- Teams can create and update schedules directly from the work package plan
- Supports classic project planning needs in a visual timeline format

**Best fit:**
PMs, coordinators, and teams managing deadlines and dependencies.

---

## Slide 8 — Roadmaps and release planning

## Roadmap view for versions and milestones

- Use versions/releases to group deliverables
- Visualize upcoming milestones and target dates
- Track progress toward planned releases
- Communicate delivery plans to stakeholders

**Typical use cases:**
- Product release planning
- Program milestones
- Portfolio communication
- Phase-gate planning

---

## Slide 9 — Kanban style in OpenProject

## How Kanban works in OpenProject (OPR)

- Best fit for teams running continuous flow delivery
- Closest Jira concept: Kanban board
- Configure board columns around workflow status (e.g., New, In progress, Done)
- Cards represent work packages and move across columns as status changes
- Use board filters for role, assignee, priority, or team-specific views
- Daily execution model:
  - pull next work item
  - move items forward as work progresses
  - surface blocked items quickly

**Presenter note:**
Position Kanban as the default style when the team does not work in fixed sprint cycles.

---

## Slide 10 — Sprint style in OpenProject

## How Sprint works in OpenProject (OPR)

- Best fit for teams using time-boxed iterations
- Closest Jira concept: Scrum board with backlog and sprint planning
- Maintain a prioritized backlog of work packages/user stories
- Plan each sprint by selecting backlog items into the sprint scope
- Use story points for estimation and track execution on the sprint board
- During sprint:
  - update status of committed items
  - monitor in-progress vs. done work
  - re-plan only when needed to protect sprint focus
- End of sprint:
  - review completed vs. carry-over items
  - adjust next sprint scope based on team capacity

**Presenter note:**
Emphasize that Kanban and Sprint can coexist by team or project context.

---

## Slide 11 — Team planner

## Capacity and assignment visibility

- Team planner provides an overview of who is working on what
- Helps teams:
  - see assignments over time
  - schedule and reschedule work
  - balance workload
  - reassign work when priorities change
- Useful when multiple people or disciplines need coordinated delivery

**Presenter note:**
Position team planner as a bridge between task execution and resource awareness.

---

## Slide 12 — Search, filters, queries, and exports

## Making information actionable

- Build filtered views for different roles
- Closest Jira concept: saved filters/JQL result views
- Save custom queries for repeated reporting or working views
- Export data for offline analysis or stakeholder sharing
- Create role-specific views, e.g.:
  - My open tasks
  - Delayed milestones
  - Risks by owner
  - Current sprint items
  - Tasks due this week

**Presenter note:**
This is often a major adoption driver because it helps each user see only what matters.

---

## Slide 13 — Roles, permissions, and governance

## Controlling who can do what

- OpenProject supports role-based permissions
- Closest Jira concept: permission schemes and project roles
- Permissions can be managed by project and by module
- Helps balance openness with governance and compliance needs

## Role-based usage patterns

### Project admin
- creates and configures the project workspace
- manages members/groups, roles, modules, and project-level settings
- can create/edit/reprioritize all work packages, boards, timelines, and reports

### Member
- creates and updates work packages and collaborates through boards/comments
- updates status, estimates, and remaining work on assigned items
- logs time and contributes to day-to-day delivery execution

### Reader
- view-only access to project content, status, milestones, and reports
- can follow progress and risks without changing project data
- suitable for leadership, customers, and other stakeholders needing transparency

**Key message:**
The platform can be collaborative without losing control.

---

## Slide 14 — Customization and workflows

## Adapting OpenProject to your process

- Configure work package types per project
- Closest Jira concept: issue types, workflows, fields, and project-level schemes
- Use custom fields for business-specific metadata
- Define statuses and workflows
- Enable only the modules needed per project
- Support different use cases in one platform:
  - software delivery
  - PMO project tracking
  - operations improvement
  - implementation programs
  - public-sector project governance

**Presenter note:**
Stress flexibility, but also recommend controlled governance to avoid over-customization.

---

## Slide 15 — Integrations and API

## Extending OpenProject

- REST API support for automation and external integrations
- Integrations are available for selected systems and workflows
- Can be connected into broader delivery ecosystems
- Useful for:
  - system integration
  - reporting automation
  - workflow synchronization
  - specialized use cases such as BIM via BCF API

**Key message:**
OpenProject can operate as part of a wider tool landscape, not only as a standalone app.

---

## Slide 16 — Typical end-to-end workflow

## Example: how a team uses OpenProject

1. Create a project and define members
2. Enable needed modules (work packages, Gantt, boards, meetings, documents, etc.)
3. Define structure: types, versions, milestones, categories, custom fields
4. Create work packages and assign owners
5. Build timeline in Gantt and confirm dependencies
6. Execute work in lists, boards, and team planner
7. Run meetings and capture decisions/actions
8. Log effort and monitor progress, delays, and cost
9. Report status through filtered views, exports, and roadmap snapshots
10. Close project or release and retain the delivery history

**Presenter note:**
This is a good anchor slide because it ties the modules into one practical story.
Call out the Jira equivalent flow: project setup -> issue setup -> board/timeline execution -> reporting.

---

## Slide 17 — Strengths to highlight

## Main benefits of OpenProject

- One central system for project execution and collaboration
- Supports multiple project management styles
- Strong transparency and traceability
- Open source positioning and extensibility
- Broad functional coverage across planning, execution, collaboration, and reporting

---

## Slide 18 — Jira to OpenProject migration work

## How migration is handled

- Migration goal: preserve Jira working context while adopting OpenProject concepts
- Core mapping used during migration:
  - Jira Project -> OpenProject Project
  - Jira Issue -> OpenProject Work package
  - Jira Epic link -> OpenProject Epic relation
  - Jira Sprint/Board context -> OpenProject Sprint/Kanban boards
- Data migration work includes:
  - issue metadata and statuses
  - comments/activity history backfill
  - users/groups and assignment continuity
  - story points and planning fields
- Post-migration validation:
  - key reports match expected counts
  - boards and workflows reflect team operating model
  - teams can continue delivery without process reset

---

## Slide 19 — Major user-visible improvements

## What has improved for end users

1. Epic-link support
- Users can link work packages to Epics directly for clearer traceability across hierarchy and delivery planning.

2. All board types enabled
- Teams can use Kanban/status-style and other board configurations without edition-based restrictions.

3. Story points available on all work packages
- Estimation with story points is no longer limited to selected types, enabling one consistent planning model.

4. Simpler member management through groups
- Project member administration is easier with group-based assignment and clearer visibility of inherited members.

**Presenter note:**
Position this slide as "what changed in daily usage" for Jira-experienced teams.

---

## Slide 20 — Features we might use in future

## Optional modules for later rollout phases

### Meetings
- Agenda creation and participant management
- Meeting minutes, decisions, and recurring meeting support
- Follow-up actions linked to project execution

### Documents and collaboration
- Central document storage and sharing in project context
- Comments, notifications, and activity history on work packages
- Better traceability vs. scattered email/file/chat threads

### Time tracking, cost reporting, and budgeting
- Time logging on work packages
- Effort vs. plan visibility for project managers
- Cost and budget tracking for delivery governance

**Presenter note:**
Position this as phase-2/phase-3 capabilities after core planning and execution adoption.

---

## Slide 21 — Key takeaways

## Summary

- OpenProject is a flexible open source project management platform
- Its center of gravity is the **work package**, supported by timelines, boards, collaboration, and reporting
- It can support classic, agile, and hybrid delivery models
- The platform is most effective when configured with clear governance and role-based usage
- It is well suited for organizations seeking transparency, structure, and extensibility

---

## Slide 22 — Q&A / discussion

## Questions?

Suggested discussion prompts:
- Which use cases matter most for our organization?
- Which modules are essential for phase 1?
- What reporting and governance requirements do we need to support?
- Do we want a classic, agile, or hybrid rollout model?

---
