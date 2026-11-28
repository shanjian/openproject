---
marp: true
theme: default
paginate: true
size: 16:9
style: |
  section {
    font-family: "Aptos", "Segoe UI", "Calibri", "Helvetica Neue", sans-serif;
    color: #16324f;
    background: linear-gradient(160deg, #f7fbff 0%, #eef5fb 100%);
    padding: 52px 62px;
    font-size: 25px;
    line-height: 1.34;
  }

  h1, h2 {
    color: #0d2b45;
    margin-bottom: 0.3em;
    line-height: 1.15;
  }

  h1 {
    font-size: 1.58em;
    letter-spacing: 0.01em;
  }

  h2 {
    font-size: 1.15em;
    color: #114066;
  }

  strong {
    color: #0f6a8f;
  }

  ul, ol {
    margin-top: 0.35em;
    padding-right: 28px;
  }

  li {
    margin: 0.2em 0;
  }

  .small {
    font-size: 0.78em;
    color: #40627f;
  }

  section::before {
    content: "OpenProject Overview";
    position: absolute;
    top: 16px;
    left: 62px;
    font-size: 0.42em;
    letter-spacing: 0.08em;
    text-transform: uppercase;
    color: #5d7b95;
  }
---

# 1. Presentation goals

## What this presentation covers

- What OpenProject is and where it fits
- Core functionality and main modules
- Jira-to-OpenProject concept mapping
- Typical role model and usage patterns
- Migration and user-visible improvements

<p class="small">This is an overview session, not detailed system training.</p>

---

# 2. Why we choose OpenProject

## Core reasons

- Strong project collaboration functionality
- Open source and customizable to our needs
- One shared view of project work and status
- Better planning of scope, schedule, and ownership
- Transparent progress tracking across teams

---

# 3. Functional map

## OpenProject capability areas

- **Planning:** Projects, work packages, milestones, Gantt, roadmaps
- **Agile execution:** Boards, backlogs, sprint planning, team planner
- **Collaboration:** Meetings, comments, activity history, documents
- **Control/reporting:** Status, time/cost, filters, queries, exports
- **Platform:** Roles, workflows, custom fields, API integrations

<p class="small">Jira mapping baseline: Project -> Project, Issue -> Work package, Board -> Board, JQL/filter -> Query/filter.</p>

---

# 4. Core concept: projects

## Projects are the main organizing structure

- Closest Jira concept: **Project**
- Workspace boundary for members, modules, settings, and reporting
- Can represent initiatives, products, departments, programs, or clients
- Controls project-specific types, categories, versions, and workflows

**Why it matters:** governance and clarity without losing flexibility.

---

# 5. Core concept: work packages

## Work package = central unit of work

- Closest Jira concept: **Issue**
- Represents tasks, stories, bugs, features, risks, and milestones
- Main fields: type, status, assignee, priority, dates, estimates
- Core object for planning, execution, and reporting

---

# 6. Structuring work packages

## How work is organized

- Parent/child hierarchy for decomposition
- Relations: precedes, follows, blocks, duplicates, relates
- Versions and milestones for release/phase planning
- Categories and custom fields for business structure
- Saved queries for focused working views

---

# 7. Planning with Gantt charts

## Timeline and dependency management

- Visualize tasks and milestones over time
- Map dependency chains and delivery sequence
- Identify date conflicts early
- Keep deadline alignment across teams

**Best fit:** PMs and coordinators managing schedule risk.

---

# 8. Roadmaps and release planning

## Roadmap view for versions and milestones

- Group deliverables by version/release
- Show upcoming milestones and target dates
- Track progress at release/program level
- Communicate direction to stakeholders

**Roadmap vs Gantt:** strategic view vs detailed schedule view.

---

# 9. Kanban style in OpenProject

## How Kanban works in OPR

- Closest Jira concept: **Kanban board**
- Status-based columns with card movement by progress
- Continuous flow model without fixed sprint timeboxes
- Team focuses on pull flow and blocker visibility

---

# 10. Sprint style in OpenProject

## How Sprint works in OPR

- Closest Jira concept: **Scrum board + backlog**
- Prioritize backlog and commit iteration scope
- Track execution of sprint items with story points
- Review completed vs carry-over items each cycle

---

# 11. Team planner

## Capacity and assignment visibility

- See who is working on what over time
- Balance load and reschedule quickly
- Coordinate handoffs across roles/disciplines

---

# 12. Search, filters, queries, and exports

## Making information actionable

- Build filtered views by role/team
- Save reusable queries for day-to-day work
- Export data for stakeholder communication
- Example views: `My tasks`, `Delayed milestones`, `Current sprint items`

---

# 13. Roles, permissions, and governance

## Simple 3-role model

- Closest Jira concept: project roles + permission schemes
- Permissions controlled by project and module

### Project admin
- Configure project, members/groups, workflows, modules

### Member
- Create/update work and execute daily delivery

### Reader
- View-only access for status and reporting

---

# 14. Customization and workflows

## Adapting OpenProject to process

- Configure work package types, statuses, and transitions
- Add custom fields for business metadata
- Enable only required modules by project
- Support software, PMO, operations, and program use cases

**Recommendation:** keep customization governed and minimal at phase 1.

---

# 15. Integrations and API

## Extending OpenProject

- REST API for automation and system integration
- Connect to reporting and surrounding tool ecosystem
- Support workflow synchronization scenarios
- Extend for specialized use cases (including BIM/BCF)

---

# 16. Typical end-to-end workflow

## Example delivery flow

1. Create project and members
2. Enable needed modules
3. Define types, milestones, versions, fields
4. Create and assign work packages
5. Execute via board/list/planner
6. Track status and publish reporting views
7. Close release/project with retained history

---

# 17. Strengths to highlight

## Main benefits

- One system for execution + collaboration
- Supports classic, agile, and hybrid delivery
- Strong transparency and traceability
- Open-source extensibility
- Good balance of flexibility and process control

---

# 18. Jira to OpenProject migration work

## Migration approach

- Preserve Jira working context while moving to OPR
- Core mapping: Project, Issue, Epic link, Sprint/Board
- Backfill metadata, comments/history, users/groups, story points
- Validate continuity in reports, boards, and workflows

---

# 19. Major user-visible improvements

## What changed for end users

1. Epic-link support
2. All board types enabled
3. Story points available across all work package types
4. Simpler member management through groups

---

# 20. Features we might use in future

## Phase 2 / Phase 3 candidates

- **Meetings:** agendas, minutes, recurring ceremonies
- **Documents:** centralized content and collaboration history
- **Time/cost/budget:** stronger delivery control and visibility

---

# 21. Key takeaways

## Summary

- OpenProject fits Jira-experienced teams with clear concept mapping
- Work packages are the center of planning and execution
- Kanban and Sprint can coexist by team context
- Simple role model and strong governance drive adoption success
- Migration should focus on continuity, not process reset

---

# 22. Q&A / discussion

## Questions?

- Which modules are essential for phase 1?
- Which teams should pilot first?
- Which migration validations are mandatory for go-live?

