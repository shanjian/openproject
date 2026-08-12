# Markdown Work Package Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a project member paste a structured Markdown outline and have its heading hierarchy created as work packages in one action, with a mandatory preview before anything is written.

**Architecture:** Six independently-testable pieces, per `docs/superpowers/specs/2026-08-11-okr-markdown-import-design.md`: a pure `OutlineParser` (Markdown → nodes), a `Resolver` (nodes → resolved-but-unsaved `WorkPackage`s + errors, via the real `SetAttributesService`/`CreateContract` pipeline so the preview cannot drift from creation), a `PreviewComponent` (renders resolved rows), a durable `WorkPackages::ImportRun` record (the async job's `status_reference`, since `job_statuses` has a unique index per reference), a `CreateJob` (walks the tree top-down through `WorkPackages::CreateService` inside one transaction), and a thin `ImportsController` (`new` / `preview` / `create` / `show`) gated by a new `import_work_packages` permission.

**Tech Stack:** Ruby 3.4.7, Rails 8, RSpec, ViewComponent + Lookbook, GoodJob (via `ApplicationJob` / `JobStatus::ApplicationJobWithStatus`).

## Global Constraints

- No OKR-specific vocabulary anywhere in the implementation — the importer is a generic Markdown outline importer. See the spec's "Why generic, not OKR-specific".
- Create-only: no duplicate detection, no upsert. Confirmed in the spec's Requirements.
- All user-facing strings go in `config/locales/en.yml` — no hard-coded text, per project convention (`CLAUDE.md` → Translations) and the spec's own "Translations" section.
- `send_notifications: false` on every `WorkPackages::CreateService` call from the job — a 200-item import must not generate a notification storm.
- The `import_work_packages` permission's `dependencies:` must include `view_work_packages`, `add_work_packages`, `manage_subtasks`, and `assign_versions` — verified against `WorkPackages::BaseContract`'s `parent_id`/`version_id` permission gates in Task 8.
- The undo link on the result page is conditional on `delete_work_packages` — never grant it by dependency, never build a delete path that bypasses it (spec's "Undo" section, "Deliberately not done").
- Follow this repo's existing idioms exactly as found below — `ServiceResult`, `BaseServices::SetAttributes` subclasses, `ApplicationJob` + `status_reference`, `wpt.permission` blocks — rather than inventing new ones.

---

## Prerequisite verified during planning

Two research passes against the current working tree confirm every file:line the design spec cites is accurate **except** the `department` custom field format itself, `Group#ancestry_path`, and `CustomField#possible_department_values` — none of which exist on this branch. The branch is **25 commits behind `origin/epic`** (merge-base `8b5c31ded00`; verified via `git log HEAD..origin/epic --oneline | wc -l`). The spec's own "Prerequisite" section already flags this; Task 0 below makes it the first executable step instead of a note.

---

## File Structure

```
db/migrate/20260811160000_create_work_package_import_runs.rb   (new)
app/models/work_packages/import_run.rb                          (new)
app/services/work_packages/import/outline_parser.rb             (new)
app/services/work_packages/import/resolver.rb                   (new)
app/components/work_packages/import/preview_component.rb        (new)
app/components/work_packages/import/preview_component.html.erb  (new)
lookbook/previews/work_packages/import/preview_component_preview.rb (new)
app/workers/work_packages/import/create_job.rb                  (new)
app/controllers/work_packages/imports_controller.rb              (new)
app/views/work_packages/imports/new.html.erb                     (new)
app/views/work_packages/imports/show.html.erb                    (new)
config/routes.rb                                                 (modify)
config/initializers/permissions.rb                                (modify)
config/locales/en.yml                                             (modify)

spec/services/work_packages/import/outline_parser_spec.rb        (new)
spec/services/work_packages/import/resolver_spec.rb              (new)
spec/components/work_packages/import/preview_component_spec.rb   (new)
spec/workers/work_packages/import/create_job_spec.rb             (new)
spec/controllers/work_packages/imports_controller_spec.rb        (new)
spec/features/work_packages/import_spec.rb                       (new)
```

- `OutlineParser` and `Resolver` are plain Ruby classes under `app/services/work_packages/import/` — mirroring the existing `app/services/work_packages/**` tree, not a new top-level namespace.
- `ImportRun` lives under `app/models/work_packages/` (`WorkPackages::ImportRun`) because it is a work-packages-scoped concept, not a general import framework (compare `Import::JiraImport`, which is a different, admin-scoped feature — see Task 0 notes).

---

## Task 0: Sync branch with `origin/epic`

This is not a code task — it unblocks every task after it. The `department` custom field format (`config/initializers/custom_field_format.rb:79`), `CustomField#possible_department_values` (`app/models/custom_field.rb:232-234`), and `Groups::Hierarchy#ancestry_path` (`app/models/groups/hierarchy.rb:87-89`) that Task 5 depends on only exist on `origin/epic`, not on this branch.

- [ ] **Step 1: Confirm the gap**

```bash
git fetch origin
git log HEAD..origin/epic --oneline | wc -l
git diff HEAD origin/epic -- app/models/custom_field.rb
```

Expected: a non-zero commit count, and a diff showing `possible_department_values` / `possible_department_values_options` as additions only on `origin/epic`.

- [ ] **Step 2: Merge `origin/epic` into this branch**

```bash
git merge origin/epic
```

Resolve any conflicts (none expected in the files this plan touches, since they are all new files). Do not use `git reset --hard` or discard local commits — this branch's design-spec commits must survive the merge.

- [ ] **Step 3: Verify the prerequisite landed**

```bash
grep -n "possible_department_values" app/models/custom_field.rb
grep -n "def ancestry_path" app/models/groups/hierarchy.rb
```

Expected: both greps return a match.

- [ ] **Step 4: Run migrations and the existing test suite baseline**

```bash
bundle exec rails db:migrate
bundle exec rspec spec/models/custom_field_spec.rb spec/models/group_spec.rb
```

Expected: migrations apply cleanly, both specs pass. This establishes a clean baseline before adding new code.

---

## Task 1: `work_package_import_runs` migration + `WorkPackages::ImportRun` model

**Files:**
- Create: `db/migrate/20260811160000_create_work_package_import_runs.rb`
- Create: `app/models/work_packages/import_run.rb`
- Test: `spec/models/work_packages/import_run_spec.rb`

**Interfaces:**
- Produces: `WorkPackages::ImportRun` — columns `project_id`, `user_id`, `status` (`"queued"|"running"|"succeeded"|"failed"`, default `"queued"`), `source` (text, required), `created_work_package_ids` (integer array, default `[]`), `failure` (jsonb, nullable), timestamps. `belongs_to :project`, `belongs_to :user`. Every later task that creates or reads a run uses exactly these column names and the `enum :status` value strings.

- [ ] **Step 1: Write the migration**

```ruby
# db/migrate/20260811160000_create_work_package_import_runs.rb
class CreateWorkPackageImportRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :work_package_import_runs do |t|
      t.references :project, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :status, null: false, default: "queued"
      t.text :source, null: false
      t.integer :created_work_package_ids, array: true, default: [], null: false
      t.jsonb :failure

      t.timestamps
    end
  end
end
```

- [ ] **Step 2: Run the migration**

```bash
bundle exec rails db:migrate
```

Expected: `work_package_import_runs` table created, schema.rb updated.

- [ ] **Step 3: Write the failing model spec**

```ruby
# spec/models/work_packages/import_run_spec.rb
require "spec_helper"

RSpec.describe WorkPackages::ImportRun do
  it "defaults to queued status with no created work packages" do
    run = described_class.new(project: build_stubbed(:project),
                              user: build_stubbed(:user),
                              source: "# Task: Do the thing")

    expect(run.status).to eq("queued")
    expect(run.created_work_package_ids).to eq([])
  end

  it "requires source" do
    run = described_class.new(project: build_stubbed(:project), user: build_stubbed(:user))

    expect(run).not_to be_valid
    expect(run.errors[:source]).to be_present
  end

  it "exposes status as a queryable enum" do
    run = described_class.new(status: "succeeded")

    expect(run).to be_succeeded
  end
end
```

- [ ] **Step 4: Run it to verify it fails**

```bash
bundle exec rspec spec/models/work_packages/import_run_spec.rb
```

Expected: `NameError: uninitialized constant WorkPackages::ImportRun`.

- [ ] **Step 5: Write the model**

```ruby
# app/models/work_packages/import_run.rb
module WorkPackages
  class ImportRun < ApplicationRecord
    self.table_name = "work_package_import_runs"

    belongs_to :project
    belongs_to :user

    enum :status, { queued: "queued", running: "running", succeeded: "succeeded", failed: "failed" },
                  default: "queued"

    validates :source, presence: true
  end
end
```

- [ ] **Step 6: Run it to verify it passes**

```bash
bundle exec rspec spec/models/work_packages/import_run_spec.rb
```

Expected: 3 examples, 0 failures.

- [ ] **Step 7: Commit**

```bash
git add db/migrate/20260811160000_create_work_package_import_runs.rb db/schema.rb \
        app/models/work_packages/import_run.rb spec/models/work_packages/import_run_spec.rb
git commit -m "feat(import): add WorkPackages::ImportRun model and table"
```

---

## Task 2: `WorkPackages::Import::OutlineParser` — structural parsing

**Files:**
- Create: `app/services/work_packages/import/outline_parser.rb`
- Test: `spec/services/work_packages/import/outline_parser_spec.rb`

**Interfaces:**
- Produces: `WorkPackages::Import::OutlineParser.call(markdown_string) -> ServiceResult`. On success, `.result` is an `OutlineParser::Document` (`front_matter: Hash<String,String>`, `nodes: Array<OutlineParser::Node>`). Each `Node` has `level` (Integer), `type_name` (String), `subject` (String), `attributes` (Hash<String,String>, **not yet inherited** — this task only), `description` (String), `source_line` (Integer, 1-indexed), `parent_index` (Integer index into `nodes`, or `nil` for a root). On failure, `.errors` is `Array<{source_line:, message:}>` (a plain Array, not `ActiveModel::Errors` — confirmed acceptable: `ServiceResult#initialize` stores whatever `errors:` is passed as-is). Task 6's `Resolver` and Task 9's `CreateJob` consume this shape directly.

- [ ] **Step 1: Write the failing tests — front matter and headings**

```ruby
# spec/services/work_packages/import/outline_parser_spec.rb
require "spec_helper"

RSpec.describe WorkPackages::Import::OutlineParser do
  subject(:call) { described_class.call(markdown) }

  context "with front matter" do
    let(:markdown) { <<~MD }
      ---
      Project: Company OKRs
      Version: FY2026 Q3
      ---

      # Objective: Increase retention
    MD

    it "parses front matter as a hash" do
      expect(call.result.front_matter).to eq("Project" => "Company OKRs", "Version" => "FY2026 Q3")
    end

    it "parses the single root node" do
      node = call.result.nodes.first
      expect(node.level).to eq(1)
      expect(node.type_name).to eq("Objective")
      expect(node.subject).to eq("Increase retention")
      expect(node.parent_index).to be_nil
      expect(node.source_line).to eq(6)
    end
  end

  context "with nested headings" do
    let(:markdown) { <<~MD }
      # Strategic Initiative: Subscription Growth

      ## Objective: Increase retention

      ### Key Result: Renewals to 75%
    MD

    it "assigns parent_index by heading depth" do
      nodes = call.result.nodes
      expect(nodes[0].parent_index).to be_nil
      expect(nodes[1].parent_index).to eq(0)
      expect(nodes[2].parent_index).to eq(1)
    end

    it "allows multiple roots at the same depth" do
      markdown = "# Objective: A\n\n# Objective: B\n"
      nodes = described_class.call(markdown).result.nodes
      expect(nodes.map(&:parent_index)).to eq([nil, nil])
    end
  end

  context "with a skipped depth" do
    let(:markdown) { <<~MD }
      # Objective: Increase retention

      ### Key Result: Renewals to 75%
    MD

    it "fails with the offending line" do
      expect(call).to be_failure
      expect(call.errors).to eq([{ source_line: 3, message: "heading depth skips a level" }])
    end
  end

  context "starting below the top heading level" do
    let(:markdown) { <<~MD }
      ## Objective: Increase retention

      ### Key Result: Renewals to 75%
    MD

    it "treats the first heading's depth as the document root" do
      expect(call).to be_success
      expect(call.result.nodes.first.level).to eq(2)
    end
  end
end
```

- [ ] **Step 2: Run to verify it fails**

```bash
bundle exec rspec spec/services/work_packages/import/outline_parser_spec.rb
```

Expected: `NameError: uninitialized constant WorkPackages::Import::OutlineParser`.

- [ ] **Step 3: Implement front matter + heading parsing**

```ruby
# app/services/work_packages/import/outline_parser.rb
module WorkPackages
  module Import
    class OutlineParser
      Node = Struct.new(:level, :type_name, :subject, :attributes, :description,
                        :source_line, :parent_index, keyword_init: true)
      Document = Struct.new(:front_matter, :nodes, keyword_init: true)

      class ParseError < StandardError
        attr_reader :source_line

        def initialize(message, source_line)
          super(message)
          @source_line = source_line
        end
      end

      HEADING = /\A(#+)\s+(.+)\z/
      BULLET = /\A-\s+([^:]+):\s*(.*)\z/

      def self.call(markdown)
        new(markdown).call
      end

      def initialize(markdown)
        @lines = markdown.to_s.split("\n")
      end

      def call
        front_matter, index = parse_front_matter(0)
        nodes = parse_nodes(index)
        ServiceResult.success(result: Document.new(front_matter:, nodes:))
      rescue ParseError => e
        ServiceResult.failure(errors: [{ source_line: e.source_line, message: e.message }])
      end

      private

      def parse_front_matter(index)
        return [{}, index] unless @lines[index]&.strip == "---"

        front_matter = {}
        cursor = index + 1

        while cursor < @lines.length && @lines[cursor].strip != "---"
          line = @lines[cursor]
          unless line.strip.empty?
            raise ParseError.new("malformed front matter line", cursor + 1) unless line.include?(":")

            key, _sep, value = line.partition(":")
            key = key.strip
            raise ParseError.new("duplicate front matter key #{key.inspect}", cursor + 1) if front_matter.key?(key)

            front_matter[key] = value.strip
          end
          cursor += 1
        end

        raise ParseError.new("unterminated front matter", index + 1) if cursor >= @lines.length

        [front_matter, cursor + 1]
      end

      def parse_nodes(start_index)
        nodes = []
        stack = []
        root_depth = nil
        index = start_index

        while index < @lines.length
          line = @lines[index]

          if (match = HEADING.match(line))
            level = match[1].length
            type_name, _sep, subject = match[2].partition(":")
            root_depth ||= level
            raise ParseError.new("heading depth is shallower than the document root", index + 1) if level < root_depth

            stack.pop while stack.any? && stack.last[:level] >= level

            if stack.empty?
              raise ParseError.new("heading depth skips a level", index + 1) if level != root_depth

              parent_index = nil
            else
              raise ParseError.new("heading depth skips a level", index + 1) if level != stack.last[:level] + 1

              parent_index = stack.last[:index]
            end

            node = Node.new(level:, type_name: type_name.strip, subject: subject.strip,
                            attributes: {}, description: "", source_line: index + 1, parent_index:)
            nodes << node
            stack.push(level:, index: nodes.length - 1)

            index = parse_bullets(node, index + 1)
            index = parse_description(node, index)
          elsif line.strip.empty?
            index += 1
          elsif BULLET.match?(line)
            raise ParseError.new("attribute bullet before any heading", index + 1)
          else
            raise ParseError.new("unexpected content before any heading", index + 1)
          end
        end

        nodes
      end

      def parse_bullets(node, index)
        while index < @lines.length && (match = BULLET.match(@lines[index]))
          key = match[1].strip
          raise ParseError.new("duplicate attribute key #{key.inspect}", index + 1) if node.attributes.key?(key)

          node.attributes[key] = match[2].strip
          index += 1
        end

        index
      end

      def parse_description(node, index)
        description_lines = []
        while index < @lines.length && !HEADING.match?(@lines[index])
          description_lines << @lines[index]
          index += 1
        end
        node.description = description_lines.join("\n").strip

        index
      end
    end
  end
end
```

- [ ] **Step 4: Run to verify it passes**

```bash
bundle exec rspec spec/services/work_packages/import/outline_parser_spec.rb
```

Expected: 6 examples, 0 failures.

- [ ] **Step 5: Write and pass tests for bullets and description**

```ruby
# append to spec/services/work_packages/import/outline_parser_spec.rb
context "with a bullet block and prose" do
  let(:markdown) { <<~MD }
    # Objective: Increase retention
    - Accountable: jane.doe@example.com
    - Confidence: 80%

    We expect gains from onboarding.

    Multiple paragraphs are joined verbatim.
  MD

  it "parses the bullet block into attributes" do
    expect(call.result.nodes.first.attributes).to eq(
      "Accountable" => "jane.doe@example.com",
      "Confidence" => "80%"
    )
  end

  it "parses everything after the bullet block as description" do
    expect(call.result.nodes.first.description)
      .to eq("We expect gains from onboarding.\n\nMultiple paragraphs are joined verbatim.")
  end
end

context "with a duplicate attribute key" do
  let(:markdown) { <<~MD }
    # Objective: Increase retention
    - Accountable: jane.doe@example.com
    - Accountable: sam.lee@example.com
  MD

  it "fails on the duplicate" do
    expect(call).to be_failure
    expect(call.errors.first[:message]).to eq('duplicate attribute key "Accountable"')
  end
end

context "with a bullet before any heading" do
  let(:markdown) { "- Accountable: jane.doe@example.com\n" }

  it "fails" do
    expect(call).to be_failure
    expect(call.errors.first[:message]).to eq("attribute bullet before any heading")
  end
end
```

```bash
bundle exec rspec spec/services/work_packages/import/outline_parser_spec.rb
```

Expected: 9 examples, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add app/services/work_packages/import/outline_parser.rb spec/services/work_packages/import/outline_parser_spec.rb
git commit -m "feat(import): parse Markdown outlines into structural nodes"
```

---

## Task 3: `OutlineParser` — attribute inheritance

**Files:**
- Modify: `app/services/work_packages/import/outline_parser.rb`
- Modify: `spec/services/work_packages/import/outline_parser_spec.rb`

**Interfaces:**
- Modifies `Node#attributes` in place before `call` returns: each node's final `attributes` is front-matter defaults, overridden by every ancestor from root to immediate parent, overridden by the node's own bullet-declared attributes. This is the shape `Resolver` (Task 6) reads — it never has to walk ancestors itself.

- [ ] **Step 1: Write the failing inheritance tests**

```ruby
# append to spec/services/work_packages/import/outline_parser_spec.rb
context "attribute inheritance" do
  let(:markdown) { <<~MD }
    ---
    Version: FY2026 Q3
    ---

    # Objective: Increase retention
    - Organizational Unit: Marketing / Retention

    ## Key Result: Renewals to 75%
    - Accountable: sam.lee@example.com

    ## Key Result: NPS to 60
    - Organizational Unit: Marketing / Brand
  MD

  it "flows front matter down to every node" do
    expect(call.result.nodes.map { |n| n.attributes["Version"] }).to eq(["FY2026 Q3"] * 3)
  end

  it "flows an ancestor's own attribute down to descendants" do
    renewals = call.result.nodes.find { |n| n.subject == "Renewals to 75%" }
    expect(renewals.attributes["Organizational Unit"]).to eq("Marketing / Retention")
  end

  it "lets a descendant override an inherited attribute" do
    nps = call.result.nodes.find { |n| n.subject == "NPS to 60" }
    expect(nps.attributes["Organizational Unit"]).to eq("Marketing / Brand")
  end

  it "does not push a sibling's attribute across" do
    renewals = call.result.nodes.find { |n| n.subject == "Renewals to 75%" }
    nps = call.result.nodes.find { |n| n.subject == "NPS to 60" }
    expect(nps.attributes).not_to have_key("Accountable")
    expect(renewals.attributes["Accountable"]).to eq("sam.lee@example.com")
  end
end
```

- [ ] **Step 2: Run to verify it fails**

```bash
bundle exec rspec spec/services/work_packages/import/outline_parser_spec.rb
```

Expected: the 4 new examples fail — `attributes["Version"]` is `nil` because front matter and ancestor attributes are not yet merged down.

- [ ] **Step 3: Implement inheritance**

```ruby
# in app/services/work_packages/import/outline_parser.rb, replace the `call` method:
def call
  front_matter, index = parse_front_matter(0)
  nodes = parse_nodes(index)
  apply_inheritance(nodes, front_matter)
  ServiceResult.success(result: Document.new(front_matter:, nodes:))
rescue ParseError => e
  ServiceResult.failure(errors: [{ source_line: e.source_line, message: e.message }])
end
```

```ruby
# add to the private section
def apply_inheritance(nodes, front_matter)
  nodes.each do |node|
    inherited = ancestors_root_first(nodes, node).reduce(front_matter) { |acc, ancestor| acc.merge(ancestor.attributes) }
    node.attributes = inherited.merge(node.attributes)
  end
end

def ancestors_root_first(nodes, node)
  chain = []
  current = node
  chain << (current = nodes[current.parent_index]) while current.parent_index
  chain.reverse
end
```

Note: `apply_inheritance` must run once, over the whole `nodes` array, before any node's `attributes` are mutated by inheritance from a node whose own attributes are still pre-inheritance — since `ancestors_root_first` reads `ancestor.attributes` fresh each time and nodes are processed in document order (a node's ancestors always appear earlier in `nodes` and are fully bullet-parsed already, just not yet inheritance-applied themselves). Verify this is safe: run the "does not push a sibling's attribute across" test above, which would fail if inheritance order mattered.

- [ ] **Step 4: Run to verify it passes**

```bash
bundle exec rspec spec/services/work_packages/import/outline_parser_spec.rb
```

Expected: 13 examples, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add app/services/work_packages/import/outline_parser.rb spec/services/work_packages/import/outline_parser_spec.rb
git commit -m "feat(import): apply front-matter and ancestor attribute inheritance"
```

---

## Task 4: `WorkPackages::Import::Resolver` — built-in labels and simple value converters

**Files:**
- Create: `app/services/work_packages/import/resolver.rb`
- Test: `spec/services/work_packages/import/resolver_spec.rb`

**Interfaces:**
- Produces: `WorkPackages::Import::Resolver.new(project:, user:)`, private methods `#resolve_date`, `#resolve_version`, `#resolve_status`, `#resolve_priority`, and `#convert_custom_value(custom_field, raw)` for `"date" "int" "float" "bool" "string" "text" "list"` formats. `AttributeError` (raised on bad input, message-only, no source line — the caller attaches `source_line`). This task does not yet wire these into node resolution (that's Task 6) — it tests the converters directly by calling them via `send`, which is acceptable here because Task 6 will exercise them again end-to-end through `#call`.

This is a case where testing private methods directly is the right call, not a shortcut: converters are pure value transforms with no dependency on the database rows Task 5/6 need, and pinning their edge cases now (before the lookup and tree-walking machinery exists) keeps each red/green cycle fast.

- [ ] **Step 1: Write the failing converter tests**

```ruby
# spec/services/work_packages/import/resolver_spec.rb
require "spec_helper"

RSpec.describe WorkPackages::Import::Resolver do
  subject(:resolver) { described_class.new(project: build_stubbed(:project), user: build_stubbed(:user)) }

  describe "#resolve_date" do
    it "parses an ISO date" do
      expect(resolver.send(:resolve_date, "2026-09-30")).to eq(Date.new(2026, 9, 30))
    end

    it "rejects a non-ISO date" do
      expect { resolver.send(:resolve_date, "09/30/2026") }
        .to raise_error(described_class::AttributeError, /not a valid ISO date/)
    end
  end

  describe "#convert_custom_value for numeric formats" do
    let(:custom_field) { build_stubbed(:custom_field, field_format: "int") }
    let(:float_field) { build_stubbed(:custom_field, field_format: "float") }

    it "parses a plain integer" do
      expect(resolver.send(:convert_custom_value, custom_field, "42")).to eq(42)
    end

    it "tolerates a trailing percent sign" do
      expect(resolver.send(:convert_custom_value, custom_field, "80%")).to eq(80)
    end

    it "parses a float" do
      expect(resolver.send(:convert_custom_value, float_field, "0.8")).to eq(0.8)
    end

    it "raises AttributeError on garbage input" do
      expect { resolver.send(:convert_custom_value, custom_field, "not a number") }
        .to raise_error(described_class::AttributeError, /not a valid int/)
    end
  end

  describe "#convert_custom_value for bool" do
    let(:bool_field) { build_stubbed(:custom_field, field_format: "bool") }

    it "accepts yes/true as truthy" do
      expect(resolver.send(:convert_custom_value, bool_field, "yes")).to be true
      expect(resolver.send(:convert_custom_value, bool_field, "True")).to be true
    end

    it "accepts anything else as false" do
      expect(resolver.send(:convert_custom_value, bool_field, "no")).to be false
    end
  end

  describe "#convert_custom_value for string/text" do
    let(:string_field) { build_stubbed(:custom_field, field_format: "string") }

    it "passes the value through verbatim" do
      expect(resolver.send(:convert_custom_value, string_field, "Rework the sequence")).to eq("Rework the sequence")
    end
  end
end
```

- [ ] **Step 2: Run to verify it fails**

```bash
bundle exec rspec spec/services/work_packages/import/resolver_spec.rb
```

Expected: `NameError: uninitialized constant WorkPackages::Import::Resolver`.

- [ ] **Step 3: Implement the class skeleton and simple converters**

```ruby
# app/services/work_packages/import/resolver.rb
module WorkPackages
  module Import
    class Resolver
      class AttributeError < StandardError; end

      ResolvedRow = Struct.new(:node, :work_package, :attribute_matches, :errors, keyword_init: true)

      def initialize(project:, user:)
        @project = project
        @user = user
      end

      private

      def resolve_date(raw)
        Date.iso8601(raw.strip)
      rescue ArgumentError
        raise AttributeError, "#{raw.inspect} is not a valid ISO date (YYYY-MM-DD)"
      end

      def resolve_version(raw)
        version = @project.versions.find_by(name: raw.strip)
        raise AttributeError, "no version named #{raw.inspect} in this project" unless version

        version
      end

      def resolve_status(raw)
        status = Status.find_by(name: raw.strip)
        raise AttributeError, "no status named #{raw.inspect}" unless status

        status
      end

      def resolve_priority(raw)
        priority = IssuePriority.find_by(name: raw.strip)
        raise AttributeError, "no priority named #{raw.inspect}" unless priority

        priority
      end

      def convert_custom_value(custom_field, raw)
        case custom_field.field_format
        when "date" then resolve_date(raw).iso8601
        when "int" then Integer(raw.delete("%").strip)
        when "float" then Float(raw.delete("%").strip)
        when "bool" then %w[yes true].include?(raw.strip.downcase)
        when "list" then resolve_list_option(custom_field, raw)
        else raw
        end
      rescue ArgumentError
        raise AttributeError, "#{raw.inspect} is not a valid #{custom_field.field_format} value"
      end

      def resolve_list_option(custom_field, raw)
        option = custom_field.custom_options.find_by(value: raw.strip)
        raise AttributeError, "#{raw.inspect} is not an option of #{custom_field.name}" unless option

        option
      end
    end
  end
end
```

- [ ] **Step 4: Run to verify it passes**

```bash
bundle exec rspec spec/services/work_packages/import/resolver_spec.rb
```

Expected: 9 examples, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add app/services/work_packages/import/resolver.rb spec/services/work_packages/import/resolver_spec.rb
git commit -m "feat(import): add Resolver value converters for simple custom field formats"
```

---

## Task 5: `Resolver` — batched user and department lookups

**Files:**
- Modify: `app/services/work_packages/import/resolver.rb`
- Modify: `spec/services/work_packages/import/resolver_spec.rb`

**Interfaces:**
- Produces: `#resolve_user(raw)` and `#resolve_department(raw)`, backed by `#build_user_lookup` / `#build_department_lookup`, called once per `Resolver#call` (wired in Task 6) and memoized into `@user_lookup` / `@department_lookup`. Both raise `AttributeError` on not-found or ambiguous input. This task tests them the same way as Task 4 — direct calls after manually assigning the memoized ivars, since the batching methods take no per-row argument.

**Depends on:** Task 0 (`Group.organizational_units`, `.in_tree_order`, `#ancestry_path` must exist).

- [ ] **Step 1: Write the failing user-lookup tests**

```ruby
# append to spec/services/work_packages/import/resolver_spec.rb
describe "#resolve_user" do
  let!(:jane) { create(:user, mail: "jane.doe@example.com", firstname: "Jane", lastname: "Doe") }
  let!(:sam) { create(:user, mail: "sam.lee@example.com", firstname: "Sam", lastname: "Lee") }

  before { resolver.instance_variable_set(:@user_lookup, resolver.send(:build_user_lookup)) }

  it "resolves by email" do
    expect(resolver.send(:resolve_user, "jane.doe@example.com")).to eq(jane)
  end

  it "resolves by unambiguous display name" do
    expect(resolver.send(:resolve_user, jane.name)).to eq(jane)
  end

  it "raises on an unknown email" do
    expect { resolver.send(:resolve_user, "nobody@example.com") }
      .to raise_error(described_class::AttributeError, /no user found with email/)
  end

  context "with two users sharing a display name" do
    let!(:other_jane) { create(:user, mail: "jane.doe2@example.com", firstname: "Jane", lastname: "Doe") }

    it "raises ambiguity, not a silent guess" do
      expect { resolver.send(:resolve_user, jane.name) }
        .to raise_error(described_class::AttributeError, /matches more than one user/)
    end
  end
end
```

- [ ] **Step 2: Run to verify it fails**

```bash
bundle exec rspec spec/services/work_packages/import/resolver_spec.rb
```

Expected: `NoMethodError: undefined method 'build_user_lookup'`.

- [ ] **Step 3: Implement user lookup**

```ruby
# add to the private section of app/services/work_packages/import/resolver.rb
def build_user_lookup
  users = User.where(status: User.statuses[:active]).to_a
  {
    by_mail: users.index_by { |u| u.mail.to_s.downcase },
    by_name: users.group_by { |u| u.name.downcase }
  }
end

def resolve_user(raw)
  raw = raw.strip

  if raw.include?("@")
    user = @user_lookup[:by_mail][raw.downcase]
    raise AttributeError, "no user found with email #{raw.inspect}" unless user

    user
  else
    matches = @user_lookup[:by_name][raw.downcase] || []
    raise AttributeError, "no user found named #{raw.inspect}" if matches.empty?
    raise AttributeError, "#{raw.inspect} matches more than one user" if matches.size > 1

    matches.first
  end
end
```

- [ ] **Step 4: Run to verify it passes**

```bash
bundle exec rspec spec/services/work_packages/import/resolver_spec.rb
```

Expected: 13 examples, 0 failures.

- [ ] **Step 5: Write the failing department-lookup tests, including the security-group regression**

```ruby
# append to spec/services/work_packages/import/resolver_spec.rb
describe "#resolve_department" do
  let!(:marketing) { create(:group, lastname: "Marketing", organizational_unit: true) }
  let!(:retention) { create(:group, lastname: "Retention", parent: marketing, organizational_unit: true) }
  let!(:security_group) { create(:group, lastname: "Retention", organizational_unit: false) }

  before { resolver.instance_variable_set(:@department_lookup, resolver.send(:build_department_lookup)) }

  it "resolves a full ancestry path" do
    expect(resolver.send(:resolve_department, "Marketing / Retention")).to eq(retention)
  end

  it "resolves an unambiguous leaf name" do
    expect(resolver.send(:resolve_department, "Marketing")).to eq(marketing)
  end

  it "never matches a same-named regular security group" do
    # "Retention" as a bare leaf name is ambiguous between the org unit and the
    # regular group only if both are considered — assert only the org unit counts.
    expect(resolver.send(:build_department_lookup)[:by_leaf_name]["Retention"]).to eq([retention])
  end

  it "raises on an unknown path" do
    expect { resolver.send(:resolve_department, "Sales / Enablement") }
      .to raise_error(described_class::AttributeError, /no organizational unit/)
  end
end
```

- [ ] **Step 6: Run to verify it fails**

```bash
bundle exec rspec spec/services/work_packages/import/resolver_spec.rb
```

Expected: `NoMethodError: undefined method 'build_department_lookup'`.

- [ ] **Step 7: Implement department lookup**

```ruby
# add to the private section
def build_department_lookup
  departments = Group.organizational_units.in_tree_order
  {
    by_leaf_name: departments.group_by(&:name),
    by_path: departments.index_by(&:ancestry_path)
  }
end

def resolve_department(raw)
  raw = raw.strip

  if raw.include?("/")
    department = @department_lookup[:by_path][raw]
    raise AttributeError, "no organizational unit at path #{raw.inspect}" unless department

    department
  else
    matches = @department_lookup[:by_leaf_name][raw] || []
    raise AttributeError, "no organizational unit named #{raw.inspect}" if matches.empty?
    raise AttributeError, "#{raw.inspect} matches more than one organizational unit; use the full path" if matches.size > 1

    matches.first
  end
end
```

Note the regression this guards against: `Group.organizational_units` scopes to `organizational_unit: true` (`app/models/groups/scopes/organizational_units.rb:36-38`) before `in_tree_order` runs, so `security_group` (a same-named, non-org-unit `Group`) never enters `by_leaf_name`. Using bare `Group.in_tree_order` here would put both `Retention` groups in the same leaf-name bucket and make every department import ambiguous.

- [ ] **Step 8: Run to verify it passes**

```bash
bundle exec rspec spec/services/work_packages/import/resolver_spec.rb
```

Expected: 17 examples, 0 failures.

- [ ] **Step 9: Assert the query count directly** (per the spec's Testing section: "assert the department lookup issues one query, not N")

```ruby
# append to spec/services/work_packages/import/resolver_spec.rb
describe "#build_department_lookup query count" do
  before do
    marketing = create(:group, lastname: "Marketing", organizational_unit: true)
    5.times { |i| create(:group, lastname: "Team #{i}", parent: marketing, organizational_unit: true) }
  end

  it "issues exactly one query regardless of tree size" do
    expect { resolver.send(:build_department_lookup) }.to make_database_queries(count: 1)
  end
end
```

```bash
bundle exec rspec spec/services/work_packages/import/resolver_spec.rb
```

Expected: 18 examples, 0 failures. (`make_database_queries` is provided by the `rspec-sqlimit` matcher already used elsewhere in this suite — confirm with `grep -rn "make_database_queries" spec/ | head -1` before running; if the matcher is unavailable, replace with a manual `ActiveSupport::Notifications.subscribe("sql.active_record")` counter.)

- [ ] **Step 10: Commit**

```bash
git add app/services/work_packages/import/resolver.rb spec/services/work_packages/import/resolver_spec.rb
git commit -m "feat(import): add Resolver user and department lookups"
```

---

## Task 6: `Resolver#call` — full node resolution

**Files:**
- Modify: `app/services/work_packages/import/resolver.rb`
- Modify: `spec/services/work_packages/import/resolver_spec.rb`

**Interfaces:**
- Produces: `Resolver#call(document)` where `document` is an `OutlineParser::Document` (Task 3's output). Returns `ServiceResult` — `.failure?` only for a document-level front-matter `Project` mismatch (`.errors` is `Array<{source_line:, message:}>` with one entry); otherwise `.success?` with `.result` = `Array<ResolvedRow>`, one per node, in document order (**not yet linked to real database ids for `parent_id`** — see the spec's "Known limitation": parent-dependent validation is deferred to `CreateJob`, Task 9). Each `ResolvedRow#errors` is `Array<{source_line:, message:}>`; a row with a non-empty `errors` still has whatever `work_package` could be built. `ResolvedRow#attribute_matches` is `Array<{label:, formatted:}>` for `PreviewComponent` (Task 7) to render.
- Consumes: `WorkPackages::SetAttributesService`, `WorkPackages::CreateContract` (both existing, unmodified), `Task 2/3`'s `OutlineParser::Document`/`Node`, `Task 4/5`'s converters.

- [ ] **Step 1: Write the failing end-to-end resolution tests**

```ruby
# append to spec/services/work_packages/import/resolver_spec.rb
describe "#call" do
  let(:project) { create(:project, types: [task_type]) }
  let(:task_type) { create(:type_task, name: "Task") }
  let!(:jane) { create(:user, mail: "jane.doe@example.com", member_in_project: project) }

  def document(markdown)
    WorkPackages::Import::OutlineParser.call(markdown).result
  end

  it "resolves a single node into an unsaved, contract-valid work package" do
    doc = document("# Task: Rework the renewal reminder sequence\n")
    result = described_class.new(project:, user: jane).call(doc)

    expect(result).to be_success
    row = result.result.first
    expect(row.errors).to be_empty
    expect(row.work_package).not_to be_persisted
    expect(row.work_package.subject).to eq("Rework the renewal reminder sequence")
    expect(row.work_package.type).to eq(task_type)
  end

  it "resolves Accountable to the built-in responsible field" do
    doc = document(<<~MD)
      # Task: Rework the sequence
      - Accountable: jane.doe@example.com
    MD
    row = described_class.new(project:, user: jane).call(doc).result.first

    expect(row.work_package.responsible).to eq(jane)
    expect(row.attribute_matches).to include(label: "Accountable", formatted: "#{jane.name} (#{jane.mail})")
  end

  it "records an error against the source line for an unknown type" do
    doc = document("# Epic: Not enabled in this project\n")
    row = described_class.new(project:, user: jane).call(doc).result.first

    expect(row.errors).to eq([{ source_line: 1, message: 'unknown or disabled work package type "Epic"' }])
  end

  it "records an error for an attribute matching no built-in label and no custom field" do
    doc = document(<<~MD)
      # Task: Rework the sequence
      - Not A Real Field: whatever
    MD
    row = described_class.new(project:, user: jane).call(doc).result.first

    expect(row.errors).to eq([{ source_line: 1, message: 'Not A Real Field: no field named "Not A Real Field" on type "Task"' }])
  end

  it "rejects a document whose front matter Project does not match" do
    doc = document(<<~MD)
      ---
      Project: Some Other Project
      ---

      # Task: Rework the sequence
    MD
    result = described_class.new(project:, user: jane).call(doc)

    expect(result).to be_failure
    expect(result.errors.first[:message]).to include("Some Other Project")
  end
end
```

- [ ] **Step 2: Run to verify it fails**

```bash
bundle exec rspec spec/services/work_packages/import/resolver_spec.rb
```

Expected: `NoMethodError: undefined method 'call' for an instance of WorkPackages::Import::Resolver`.

- [ ] **Step 3: Implement `#call` and node resolution**

```ruby
# replace the `private` line and everything after `initialize` in app/services/work_packages/import/resolver.rb
# with the block below, keeping the existing converter/lookup methods:

BUILTIN_ATTRIBUTE_KEYS = {
  "Accountable" => :responsible_id,
  "Assignee" => :assigned_to_id,
  "Version" => :version_id,
  "Status" => :status_id,
  "Priority" => :priority_id,
  "Start date" => :start_date,
  "Finish date" => :due_date
}.freeze

def call(document)
  mismatch = front_matter_project_mismatch(document.front_matter)
  return ServiceResult.failure(errors: [mismatch]) if mismatch

  @user_lookup = build_user_lookup
  @department_lookup = build_department_lookup

  ServiceResult.success(result: document.nodes.map { |node| resolve_node(node) })
end

private

def front_matter_project_mismatch(front_matter)
  declared = front_matter["Project"]
  return nil if declared.blank? || declared == @project.name

  { source_line: 1, message: "document declares Project: #{declared.inspect}, but is being imported into #{@project.name.inspect}" }
end

def resolve_node(node)
  type = @project.types.find_by(name: node.type_name)

  if type.nil?
    return ResolvedRow.new(node:, work_package: nil, attribute_matches: [],
                            errors: [{ source_line: node.source_line, message: "unknown or disabled work package type #{node.type_name.inspect}" }])
  end

  work_package = WorkPackage.new(project: @project)
  attributes = { type_id: type.id, subject: node.subject, description: node.description }
  attribute_matches = []
  errors = []

  node.attributes.each do |label, raw_value|
    resolved = resolve_attribute(type, label, raw_value)
    attributes[resolved[:key]] = resolved[:value]
    attribute_matches << { label:, formatted: resolved[:formatted] }
  rescue AttributeError => e
    errors << { source_line: node.source_line, message: "#{label}: #{e.message}" }
  end

  result = WorkPackages::SetAttributesService
    .new(user: @user, model: work_package, contract_class: WorkPackages::CreateContract)
    .call(attributes)

  errors.concat(result.errors.full_messages.map { |message| { source_line: node.source_line, message: } }) if result.failure?

  ResolvedRow.new(node:, work_package: result.result, attribute_matches:, errors:)
end

def resolve_attribute(type, label, raw_value)
  if BUILTIN_ATTRIBUTE_KEYS.key?(label)
    resolve_builtin_attribute(label, raw_value)
  else
    resolve_custom_field_attribute(type, label, raw_value)
  end
end

def resolve_builtin_attribute(label, raw_value)
  value =
    case label
    when "Accountable", "Assignee" then resolve_user(raw_value)
    when "Version" then resolve_version(raw_value)
    when "Status" then resolve_status(raw_value)
    when "Priority" then resolve_priority(raw_value)
    when "Start date", "Finish date" then resolve_date(raw_value)
    end

  { key: BUILTIN_ATTRIBUTE_KEYS.fetch(label),
    value: value.is_a?(ActiveRecord::Base) ? value.id : value,
    formatted: format_value(value) }
end

def resolve_custom_field_attribute(type, label, raw_value)
  custom_field = type.custom_fields.find_by(name: label)
  raise AttributeError, "no field named #{label.inspect} on type #{type.name.inspect}" unless custom_field

  value = custom_field.field_format == "user" ? resolve_user(raw_value)
        : custom_field.field_format == "department" ? resolve_department(raw_value)
        : custom_field.field_format == "hierarchy" ? resolve_list_option(custom_field, raw_value)
        : convert_custom_value(custom_field, raw_value)

  stored_value = value.is_a?(ActiveRecord::Base) ? value.id.to_s : value

  { key: :"custom_field_#{custom_field.id}", value: stored_value, formatted: format_value(value) }
end

def format_value(value)
  case value
  when User then "#{value.name} (#{value.mail})"
  when Group then value.ancestry_path
  when ActiveRecord::Base then value.respond_to?(:name) ? value.name : value.to_s
  else value.to_s
  end
end
```

`resolve_custom_field_attribute`'s `"hierarchy"` branch reuses `resolve_list_option` as a placeholder value-lookup strategy (matching on `custom_options`) because this repo's hierarchy custom field format was not exercised by any file read during planning. Before writing a test for a hierarchy-format field, inspect `app/models/custom_field/hierarchy` (or run `bin/rails runner 'puts CustomField.where(field_format: "hierarchy").first&.class'` against seed data) to confirm whether hierarchy values are actually `CustomOption` records or a distinct `Item` model, and adjust this branch accordingly. The OKR sample document in the spec does not use the `hierarchy` format (it uses `department` for Organizational Unit), so this is not on the critical path for Task 11's feature spec.

- [ ] **Step 4: Run to verify it passes**

```bash
bundle exec rspec spec/services/work_packages/import/resolver_spec.rb
```

Expected: 23 examples, 0 failures.

- [ ] **Step 5: Add the OKR-shaped fixture test (Baseline/Target/Confidence/OKR Health as custom fields)**

```ruby
# append to spec/services/work_packages/import/resolver_spec.rb
describe "#call with a full OKR-shaped Key Result" do
  let(:project) { create(:project, types: [key_result_type]) }
  let(:key_result_type) { create(:type, name: "Key Result", custom_fields: [baseline_field, confidence_field]) }
  let(:baseline_field) { create(:custom_field, name: "Baseline", field_format: "int", types: [key_result_type]) }
  let(:confidence_field) { create(:custom_field, name: "Confidence", field_format: "int", types: [key_result_type]) }
  let!(:sam) { create(:user, mail: "sam.lee@example.com", member_in_project: project) }

  before do
    baseline_field.types << key_result_type unless baseline_field.types.include?(key_result_type)
    confidence_field.types << key_result_type unless confidence_field.types.include?(key_result_type)
  end

  it "resolves every custom field to its stored value" do
    doc = document(<<~MD)
      # Key Result: Increase annual renewals from 65% to 75%
      - Accountable: sam.lee@example.com
      - Baseline: 65%
      - Confidence: 75%
    MD
    row = described_class.new(project:, user: sam).call(doc).result.first

    expect(row.errors).to be_empty
    expect(row.work_package.responsible).to eq(sam)
    expect(row.work_package.send(:"custom_field_#{baseline_field.id}")).to eq("65")
    expect(row.work_package.send(:"custom_field_#{confidence_field.id}")).to eq("75")
  end
end
```

- [ ] **Step 6: Run to verify it passes; adjust factory traits if `member_in_project` / `custom_field` factories differ**

```bash
bundle exec rspec spec/services/work_packages/import/resolver_spec.rb
```

If `member_in_project` isn't a recognized trait on the `:user` factory, check `spec/factories/users_factory.rb` for the actual trait name (likely `member_in_project:` already exists given it's used elsewhere for project-scoped user setup — confirm with `grep -n "member_in_project" spec/factories/users_factory.rb`) and adjust the test accordingly; this is a factory-shape detail, not a design decision.

Expected: 24 examples, 0 failures.

- [ ] **Step 7: Commit**

```bash
git add app/services/work_packages/import/resolver.rb spec/services/work_packages/import/resolver_spec.rb
git commit -m "feat(import): resolve outline nodes into unsaved, contract-validated work packages"
```

---

## Task 7: `WorkPackages::Import::PreviewComponent`

**Files:**
- Create: `app/components/work_packages/import/preview_component.rb`
- Create: `app/components/work_packages/import/preview_component.html.erb`
- Create: `lookbook/previews/work_packages/import/preview_component_preview.rb`
- Test: `spec/components/work_packages/import/preview_component_spec.rb`

**Interfaces:**
- Consumes: `Array<Resolver::ResolvedRow>` (Task 6's output).
- Produces: `PreviewComponent.new(rows:)`, `#any_errors?` (used by the `new.html.erb` view in Task 8 to disable the confirm button).

- [ ] **Step 1: Inspect derived-attribute and pattern APIs before writing assertions**

```bash
bin/rails runner 'puts WorkPackage.attribute_names.grep(/derived/)'
bin/rails runner 'puts Type.new.enabled_patterns.class'
```

Expected: the first prints `derived_done_ratio`, `derived_estimated_hours`, `derived_remaining_hours` (per the design spec); the second confirms whether `enabled_patterns` keys are strings or symbols, which the component's `computed_attribute_names` check below must match exactly.

- [ ] **Step 2: Write the failing component spec**

```ruby
# spec/components/work_packages/import/preview_component_spec.rb
require "spec_helper"

RSpec.describe WorkPackages::Import::PreviewComponent, type: :component do
  let(:node) { WorkPackages::Import::OutlineParser::Node.new(level: 1, type_name: "Task", subject: "Do the thing",
                                                              attributes: {}, description: "", source_line: 1, parent_index: nil) }

  it "renders each row's subject" do
    row = WorkPackages::Import::Resolver::ResolvedRow.new(node:, work_package: build(:work_package, subject: "Do the thing"),
                                                            attribute_matches: [], errors: [])
    render_inline(described_class.new(rows: [row]))

    expect(page).to have_text("Do the thing")
  end

  it "renders an attribute match" do
    row = WorkPackages::Import::Resolver::ResolvedRow.new(node:, work_package: build(:work_package),
                                                            attribute_matches: [{ label: "Accountable", formatted: "Jane Doe (jane.doe@example.com)" }],
                                                            errors: [])
    render_inline(described_class.new(rows: [row]))

    expect(page).to have_text("Accountable: Jane Doe (jane.doe@example.com)")
  end

  it "renders an inline error against its source line" do
    row = WorkPackages::Import::Resolver::ResolvedRow.new(node:, work_package: nil, attribute_matches: [],
                                                            errors: [{ source_line: 5, message: "unknown type" }])
    render_inline(described_class.new(rows: [row]))

    expect(page).to have_text("Line 5: unknown type")
  end

  describe "#any_errors?" do
    it "is true if any row has errors" do
      row = WorkPackages::Import::Resolver::ResolvedRow.new(node:, work_package: nil, attribute_matches: [],
                                                              errors: [{ source_line: 1, message: "x" }])
      expect(described_class.new(rows: [row]).any_errors?).to be true
    end

    it "is false if no row has errors" do
      row = WorkPackages::Import::Resolver::ResolvedRow.new(node:, work_package: build(:work_package), attribute_matches: [], errors: [])
      expect(described_class.new(rows: [row]).any_errors?).to be false
    end
  end
end
```

- [ ] **Step 3: Run to verify it fails**

```bash
bundle exec rspec spec/components/work_packages/import/preview_component_spec.rb
```

Expected: `NameError: uninitialized constant WorkPackages::Import::PreviewComponent`.

- [ ] **Step 4: Implement the component**

```ruby
# app/components/work_packages/import/preview_component.rb
module WorkPackages
  module Import
    class PreviewComponent < ViewComponent::Base
      DERIVED_ATTRIBUTES = %w[derived_done_ratio derived_estimated_hours derived_remaining_hours].freeze

      def initialize(rows:)
        super
        @rows = rows
      end

      def any_errors?
        @rows.any? { |row| row.errors.any? }
      end

      def computed_attribute_names(row)
        return [] unless row.work_package

        names = DERIVED_ATTRIBUTES.select { |attr| row.work_package.class.attribute_names.include?(attr) }
        names << "subject" if row.work_package.type&.enabled_patterns&.key?("subject")
        names
      end

      private

      attr_reader :rows
    end
  end
end
```

```erb
<%# app/components/work_packages/import/preview_component.html.erb %>
<ul class="work-package-import-preview">
  <% rows.each do |row| %>
    <li class="work-package-import-preview--row" style="margin-left: <%= row.node.level * 1.5 %>em">
      <strong><%= row.node.type_name %>:</strong> <%= row.node.subject %>

      <ul>
        <% row.attribute_matches.each do |match| %>
          <li><%= match[:label] %>: <%= match[:formatted] %></li>
        <% end %>
        <% computed_attribute_names(row).each do |name| %>
          <li><%= name %>: <%= t("work_packages.import.preview.computed_on_creation") %></li>
        <% end %>
      </ul>

      <% row.errors.each do |error| %>
        <p class="work-package-import-preview--error">
          <%= t("work_packages.import.preview.error_on_line", line: error[:source_line], message: error[:message]) %>
        </p>
      <% end %>
    </li>
  <% end %>
</ul>
```

Note: the `t("...error_on_line", line:, message:)` call needs its locale key defined before this view is rendered by a controller — Task 10 adds `config/locales/en.yml`. For this component spec (rendered standalone via `render_inline`), add the two keys now so the spec passes without waiting for Task 10:

```yaml
# add to config/locales/en.yml, top-level, alongside other feature blocks
work_packages:
  import:
    preview:
      computed_on_creation: "computed on creation"
      error_on_line: "Line %{line}: %{message}"
```

- [ ] **Step 5: Run to verify it passes**

```bash
bundle exec rspec spec/components/work_packages/import/preview_component_spec.rb
```

Expected: 5 examples, 0 failures.

- [ ] **Step 6: Add the Lookbook preview**

```ruby
# lookbook/previews/work_packages/import/preview_component_preview.rb
module WorkPackages
  module Import
    # @logical_path OpenProject/WorkPackages/Import
    class PreviewComponentPreview < ViewComponent::Preview
      def default
        node = WorkPackages::Import::OutlineParser::Node.new(level: 1, type_name: "Key Result",
                                                              subject: "Increase annual renewals from 65% to 75%",
                                                              attributes: {}, description: "", source_line: 6, parent_index: nil)
        row = WorkPackages::Import::Resolver::ResolvedRow.new(
          node:, work_package: WorkPackage.new(subject: node.subject),
          attribute_matches: [{ label: "Accountable", formatted: "Jane Doe (jane.doe@example.com)" },
                               { label: "Baseline", formatted: "65" }],
          errors: []
        )
        render WorkPackages::Import::PreviewComponent.new(rows: [row])
      end
    end
  end
end
```

- [ ] **Step 7: Commit**

```bash
git add app/components/work_packages/import/preview_component.rb \
        app/components/work_packages/import/preview_component.html.erb \
        lookbook/previews/work_packages/import/preview_component_preview.rb \
        spec/components/work_packages/import/preview_component_spec.rb \
        config/locales/en.yml
git commit -m "feat(import): add PreviewComponent for resolved import rows"
```

---

## Task 8: Permission, routes, `ImportsController#new` / `#preview`

**Files:**
- Modify: `config/initializers/permissions.rb`
- Modify: `config/routes.rb`
- Create: `app/controllers/work_packages/imports_controller.rb`
- Create: `app/views/work_packages/imports/new.html.erb`
- Test: `spec/controllers/work_packages/imports_controller_spec.rb`

**Interfaces:**
- Produces: permission `:import_work_packages`, routes `new_project_work_packages_import_path` / `preview_project_work_packages_imports_path` (verify exact helper names via `bin/rails routes | grep import` after adding the route — see Step 2), `WorkPackages::ImportsController#new` and `#preview`. `#create` and `#show` are added in Task 10 but must already be declared in the permission's controller-action list now, since the permission block is one atomic addition.

- [ ] **Step 1: Declare the permission**

```ruby
# config/initializers/permissions.rb — add near the add_work_packages block (around line 323)
wpt.permission :import_work_packages,
               {
                 "work_packages/imports": %i[new preview create show]
               },
               permissible_on: :project,
               dependencies: %i[view_work_packages add_work_packages
                                manage_subtasks assign_versions]
```

The four dependencies are load-bearing, not defensive padding: `WorkPackages::BaseContract` gates `parent_id` on `manage_subtasks` (`base_contract.rb:85-86`) and `version_id` on `assign_versions` (`base_contract.rb:49-52`). Since every row below a document's root sets `parent_id`, and the OKR sample sets `Version` on every node, a role holding only `view_work_packages`/`add_work_packages` cannot import the spec's own sample document — this dependency list is what Task 11's permission regression spec pins down.

- [ ] **Step 2: Add the routes**

```ruby
# config/routes.rb — add inside the existing `namespace :work_packages do ... end` block
# (alongside the existing `resource :bulk` / `resource :move` entries)
resources :imports, controller: "work_packages/imports", only: %i[new create show] do
  collection do
    post :preview
  end
end
```

```bash
bin/rails routes | grep import
```

Run this and record the actual generated path helper names in a comment at the top of `imports_controller.rb` — do not guess them from a similarly-shaped controller, since the exact prefix depends on how this `namespace` block is itself nested under the project scope.

- [ ] **Step 3: Write the failing controller spec for `new` and authorization**

```ruby
# spec/controllers/work_packages/imports_controller_spec.rb
require "spec_helper"

RSpec.describe WorkPackages::ImportsController do
  shared_let(:project) { create(:project) }

  current_user { user }

  describe "GET #new" do
    context "with import_work_packages permission" do
      let(:user) { create(:user, member_with_permissions: %i[view_work_packages add_work_packages
                                                              manage_subtasks assign_versions import_work_packages]) }

      it "renders successfully" do
        get :new, params: { project_id: project.id }

        expect(response).to have_http_status(:ok)
      end
    end

    context "without import_work_packages permission" do
      let(:user) { create(:user, member_with_permissions: %i[view_work_packages]) }

      it "is forbidden" do
        get :new, params: { project_id: project.id }

        expect(response).to have_http_status(:forbidden)
      end
    end
  end
end
```

- [ ] **Step 4: Run to verify it fails**

```bash
bundle exec rspec spec/controllers/work_packages/imports_controller_spec.rb
```

Expected: `NameError: uninitialized constant WorkPackages::ImportsController`.

- [ ] **Step 5: Implement the controller and `new` view**

```ruby
# app/controllers/work_packages/imports_controller.rb
module WorkPackages
  class ImportsController < ApplicationController
    before_action :find_project_by_project_id
    before_action :authorize

    def new
      @rows = []
      @source = ""
    end

    def preview
      @source = params[:source].to_s
      document_result = WorkPackages::Import::OutlineParser.call(@source)

      if document_result.failure?
        @rows = []
        @parse_errors = document_result.errors
      else
        resolution = WorkPackages::Import::Resolver.new(project: @project, user: current_user).call(document_result.result)

        if resolution.failure?
          @rows = []
          @parse_errors = resolution.errors
        else
          @rows = resolution.result
          @parse_errors = []
        end
      end

      render :new
    end
  end
end
```

```erb
<%# app/views/work_packages/imports/new.html.erb %>
<h2><%= t("work_packages.import.new.title") %></h2>

<%= form_tag preview_project_work_packages_imports_path(@project), method: :post do %>
  <%= text_area_tag :source, @source, rows: 20, style: "width: 100%" %>
  <%= submit_tag t("work_packages.import.new.preview_button") %>
<% end %>

<% if @parse_errors.present? %>
  <ul class="work-package-import-errors">
    <% @parse_errors.each do |error| %>
      <li><%= t("work_packages.import.preview.error_on_line", line: error[:source_line], message: error[:message]) %></li>
    <% end %>
  </ul>
<% end %>

<% if @rows.present? %>
  <%= render WorkPackages::Import::PreviewComponent.new(rows: @rows) %>

  <%= form_tag project_work_packages_imports_path(@project), method: :post do %>
    <%= hidden_field_tag :source, @source %>
    <%= submit_tag t("work_packages.import.new.confirm_button"), disabled: WorkPackages::Import::PreviewComponent.new(rows: @rows).any_errors? %>
  <% end %>
<% end %>
```

Replace `preview_project_work_packages_imports_path` / `project_work_packages_imports_path` with whatever `bin/rails routes | grep import` actually printed in Step 2 if it differs.

```yaml
# add to config/locales/en.yml under work_packages.import (created in Task 7)
    new:
      title: "Import work packages from Markdown"
      preview_button: "Preview"
      confirm_button: "Create work packages"
```

- [ ] **Step 6: Run to verify it passes**

```bash
bundle exec rspec spec/controllers/work_packages/imports_controller_spec.rb
```

Expected: 2 examples, 0 failures.

- [ ] **Step 7: Write and pass the `preview` action spec**

```ruby
# append to spec/controllers/work_packages/imports_controller_spec.rb
describe "POST #preview" do
  let(:user) { create(:user, member_with_permissions: %i[view_work_packages add_work_packages
                                                          manage_subtasks assign_versions import_work_packages]) }
  let!(:task_type) { create(:type_task, name: "Task", projects: [project]) }

  it "renders the preview and creates no work packages" do
    expect {
      post :preview, params: { project_id: project.id, source: "# Task: Rework the sequence\n" }
    }.not_to change(WorkPackage, :count)

    expect(response).to render_template(:new)
    expect(assigns(:rows).first.errors).to be_empty
  end
end
```

```bash
bundle exec rspec spec/controllers/work_packages/imports_controller_spec.rb
```

Expected: 3 examples, 0 failures.

- [ ] **Step 8: Commit**

```bash
git add config/initializers/permissions.rb config/routes.rb \
        app/controllers/work_packages/imports_controller.rb \
        app/views/work_packages/imports/new.html.erb \
        spec/controllers/work_packages/imports_controller_spec.rb \
        config/locales/en.yml
git commit -m "feat(import): add import_work_packages permission and new/preview actions"
```

---

## Task 9: `WorkPackages::Import::CreateJob`

**Files:**
- Create: `app/workers/work_packages/import/create_job.rb`
- Test: `spec/workers/work_packages/import/create_job_spec.rb`

**Interfaces:**
- Consumes: `WorkPackages::ImportRun` (Task 1), `OutlineParser`/`Resolver` (Tasks 3/6), `WorkPackages::CreateService` (existing).
- Produces: `WorkPackages::Import::CreateJob.perform_later(import_run:)`. `#status_reference` returns the passed-in run (via `arguments.first[:import_run]`, the `ExportJob`/`BackupJob` idiom). On success: run's `status` becomes `"succeeded"`, `created_work_package_ids` set. On any failure (parse, resolve, per-row error, or a `CreateService` failure): the whole transaction rolls back, run's `status` becomes `"failed"`, `failure` records `{source_line:, message:}`.

- [ ] **Step 1: Write the failing success-path test**

```ruby
# spec/workers/work_packages/import/create_job_spec.rb
require "spec_helper"

RSpec.describe WorkPackages::Import::CreateJob do
  let(:project) { create(:project) }
  let(:user) { create(:user, member_with_permissions: %i[view_work_packages add_work_packages manage_subtasks assign_versions]) }
  let!(:task_type) { create(:type_task, name: "Task", projects: [project]) }
  let!(:objective_type) { create(:type, name: "Objective", projects: [project]) }

  let(:import_run) { create(:work_packages_import_run, project:, user:, source:) }

  context "with a valid two-level document" do
    let(:source) { <<~MD }
      # Objective: Increase retention

      ## Task: Rework the sequence
    MD

    it "creates every node and links parent_id top-down" do
      perform_enqueued_jobs { described_class.perform_later(import_run:) }
      import_run.reload

      expect(import_run).to be_succeeded
      expect(import_run.created_work_package_ids.size).to eq(2)

      objective, task = WorkPackage.where(id: import_run.created_work_package_ids).order(:id)
      expect(task.parent_id).to eq(objective.id)
    end

    it "suppresses notifications" do
      expect(WorkPackages::CreateService).to receive(:new).at_least(:once).and_wrap_original do |method, **kwargs|
        method.call(**kwargs)
      end

      expect { perform_enqueued_jobs { described_class.perform_later(import_run:) } }
        .not_to have_enqueued_mail
    end
  end
end
```

`:work_packages_import_run` must exist as a factory — add it in this step:

```ruby
# spec/factories/work_packages_import_runs_factory.rb
FactoryBot.define do
  factory :work_packages_import_run, class: "WorkPackages::ImportRun" do
    project
    user
    source { "# Task: placeholder\n" }
  end
end
```

- [ ] **Step 2: Run to verify it fails**

```bash
bundle exec rspec spec/workers/work_packages/import/create_job_spec.rb
```

Expected: `NameError: uninitialized constant WorkPackages::Import::CreateJob`.

- [ ] **Step 3: Implement the job**

```ruby
# app/workers/work_packages/import/create_job.rb
module WorkPackages
  module Import
    class CreateJob < ApplicationJob
      queue_with_priority :above_normal

      class CreationFailed < StandardError
        attr_accessor :source_line

        def self.from_error(error)
          new(error[:message]).tap { |e| e.source_line = error[:source_line] }
        end
      end

      def perform(import_run:)
        self.import_run = import_run
        import_run.update!(status: :running)

        WorkPackage.transaction do
          created_ids = create_tree!
          import_run.update!(status: :succeeded, created_work_package_ids: created_ids)
        end
      rescue CreationFailed => e
        import_run.update!(status: :failed, failure: { source_line: e.source_line, message: e.message })
      end

      def status_reference
        arguments.first[:import_run]
      end

      def updates_own_status?
        true
      end

      private

      attr_accessor :import_run

      def create_tree!
        document_result = WorkPackages::Import::OutlineParser.call(import_run.source)
        raise CreationFailed.from_error(document_result.errors.first) if document_result.failure?

        resolution = WorkPackages::Import::Resolver.new(project: import_run.project, user: import_run.user)
                                                    .call(document_result.result)
        raise CreationFailed.from_error(resolution.errors.first) if resolution.failure?

        rows = resolution.result
        first_row_error = rows.flat_map(&:errors).first
        raise CreationFailed.from_error(first_row_error) if first_row_error

        created_ids = []

        rows.each_with_index do |row, index|
          parent_id = row.node.parent_index && created_ids[row.node.parent_index]

          result = WorkPackages::CreateService
            .new(user: import_run.user)
            .call(work_package: row.work_package, parent_id:, send_notifications: false)

          if result.failure?
            raise CreationFailed.from_error({ source_line: row.node.source_line, message: result.errors.full_messages.join(", ") })
          end

          created_ids[index] = result.result.id
        end

        created_ids
      end
    end
  end
end
```

- [ ] **Step 4: Run to verify it passes**

```bash
bundle exec rspec spec/workers/work_packages/import/create_job_spec.rb
```

Expected: 2 examples, 0 failures. If `parent_id` comes back `nil` on the child, check that `WorkPackages::CreateService#call` is actually re-running `SetAttributesService` on the passed-in `work_package:` with the new `parent_id:` merged in (`create_service.rb:80-82`) rather than ignoring it because the model object already has attributes set — this is the load-bearing assumption behind reusing `row.work_package` across preview and creation.

- [ ] **Step 5: Write and pass the rollback test**

```ruby
# append to spec/workers/work_packages/import/create_job_spec.rb
context "when a later node fails" do
  let(:source) { <<~MD }
    # Objective: Increase retention

    ## Task: Rework the sequence
    - Accountable: nobody@example.com
  MD

  it "rolls back every work package and records the failing line" do
    expect { perform_enqueued_jobs { described_class.perform_later(import_run:) } }
      .not_to change(WorkPackage, :count)

    import_run.reload
    expect(import_run).to be_failed
    expect(import_run.failure["source_line"]).to eq(4)
    expect(import_run.failure["message"]).to include("no user found with email")
  end
end
```

```bash
bundle exec rspec spec/workers/work_packages/import/create_job_spec.rb
```

Expected: 3 examples, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add app/workers/work_packages/import/create_job.rb \
        spec/workers/work_packages/import/create_job_spec.rb \
        spec/factories/work_packages_import_runs_factory.rb
git commit -m "feat(import): add CreateJob walking the resolved tree inside one transaction"
```

---

## Task 10: `ImportsController#create` / `#show`, undo link, locale strings

**Files:**
- Modify: `app/controllers/work_packages/imports_controller.rb`
- Create: `app/views/work_packages/imports/show.html.erb`
- Modify: `config/locales/en.yml`
- Modify: `spec/controllers/work_packages/imports_controller_spec.rb`

**Interfaces:**
- Produces: `#create` (creates the `ImportRun`, enqueues `CreateJob`, redirects to `#show`); `#show` (renders run status, the list of created work packages once succeeded, and an undo link gated on `delete_work_packages`).

- [ ] **Step 1: Write the failing `create`/`show` specs**

```ruby
# append to spec/controllers/work_packages/imports_controller_spec.rb
describe "POST #create" do
  let(:user) { create(:user, member_with_permissions: %i[view_work_packages add_work_packages
                                                          manage_subtasks assign_versions import_work_packages]) }

  it "creates an ImportRun, enqueues the job, and redirects to show" do
    expect {
      post :create, params: { project_id: project.id, source: "# Task: Rework the sequence\n" }
    }.to have_enqueued_job(WorkPackages::Import::CreateJob)

    run = WorkPackages::ImportRun.last
    expect(run.project).to eq(project)
    expect(run.user).to eq(user)
    expect(response).to redirect_to(project_work_packages_import_path(project, run))
  end
end

describe "GET #show" do
  let(:user) { create(:user, member_with_permissions: %i[view_work_packages add_work_packages
                                                          manage_subtasks assign_versions import_work_packages]) }
  let(:import_run) { create(:work_packages_import_run, project:, user:) }

  it "renders the run's status" do
    get :show, params: { project_id: project.id, id: import_run.id }

    expect(response).to have_http_status(:ok)
    expect(assigns(:import_run)).to eq(import_run)
  end

  it "is not found for a run from another project" do
    other_run = create(:work_packages_import_run, project: create(:project), user:)

    expect { get :show, params: { project_id: project.id, id: other_run.id } }
      .to raise_error(ActiveRecord::RecordNotFound)
  end

  context "when the run succeeded" do
    let(:created_work_package) { create(:work_package, project:) }
    let(:import_run) { create(:work_packages_import_run, project:, user:, status: "succeeded",
                              created_work_package_ids: [created_work_package.id]) }

    it "shows the undo link only with delete_work_packages" do
      get :show, params: { project_id: project.id, id: import_run.id }
      expect(response.body).not_to include("undo")

      allow(User).to receive(:current).and_return(user)
      user_with_delete = create(:user, member_with_permissions: %i[view_work_packages add_work_packages
                                                                    manage_subtasks assign_versions
                                                                    import_work_packages delete_work_packages])
      allow(controller).to receive(:current_user).and_return(user_with_delete)
      get :show, params: { project_id: project.id, id: import_run.id }
      expect(response.body).to include(t = I18n.t("work_packages.import.show.undo"))
      expect(response.body).to include(t)
    end
  end
end
```

- [ ] **Step 2: Run to verify it fails**

```bash
bundle exec rspec spec/controllers/work_packages/imports_controller_spec.rb
```

Expected: `AbstractController::ActionNotFound: The action 'create' could not be found`.

- [ ] **Step 3: Implement `create` and `show`**

```ruby
# add to app/controllers/work_packages/imports_controller.rb, inside the class,
# and add `before_action :find_import_run, only: :show` near the top
def create
  import_run = WorkPackages::ImportRun.create!(project: @project, user: current_user, source: params[:source])
  WorkPackages::Import::CreateJob.perform_later(import_run:)

  redirect_to project_work_packages_import_path(@project, import_run)
end

def show
  @import_run = @import_run
  @created_work_packages = WorkPackage.where(id: @import_run.created_work_package_ids)
end

private

def find_import_run
  @import_run = WorkPackages::ImportRun.where(project: @project).find(params[:id])
end
```

(Replace the placeholder `@import_run = @import_run` line — it is dead code from drafting; `find_import_run` already assigns `@import_run`, so `show` needs only the `@created_work_packages` line.)

```erb
<%# app/views/work_packages/imports/show.html.erb %>
<h2><%= t("work_packages.import.show.title") %></h2>

<p><%= t("work_packages.import.show.status", status: @import_run.status) %></p>

<% if @import_run.succeeded? %>
  <ul>
    <% @created_work_packages.each do |wp| %>
      <li><%= link_to wp.subject, work_package_path(wp) %></li>
    <% end %>
  </ul>

  <% if User.current.allowed_in_project?(:delete_work_packages, @project) %>
    <%= link_to t("work_packages.import.show.undo"),
                work_packages_bulk_path(ids: @import_run.created_work_package_ids),
                method: :delete,
                data: { confirm: t("work_packages.import.show.undo_confirm") } %>
  <% end %>
<% elsif @import_run.failed? %>
  <p class="work-package-import-errors">
    <%= t("work_packages.import.preview.error_on_line", line: @import_run.failure["source_line"], message: @import_run.failure["message"]) %>
  </p>
<% end %>
```

Verify `User#allowed_in_project?` is the correct current API for a project-scoped permission check (it is used elsewhere in views — confirm with `grep -rn "allowed_in_project?" app/views | head -3`); if this codebase uses `User.current.allowed_to?(:delete_work_packages, @project)` instead, use that form.

```yaml
# add to config/locales/en.yml under work_packages.import
    show:
      title: "Import result"
      status: "Status: %{status}"
      undo: "Undo this import"
      undo_confirm: "This will delete every work package this import created. Continue?"
```

- [ ] **Step 4: Run to verify it passes**

```bash
bundle exec rspec spec/controllers/work_packages/imports_controller_spec.rb
```

Expected: 8 examples, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add app/controllers/work_packages/imports_controller.rb \
        app/views/work_packages/imports/show.html.erb \
        config/locales/en.yml \
        spec/controllers/work_packages/imports_controller_spec.rb
git commit -m "feat(import): add create/show actions with permission-gated undo"
```

---

## Task 11: Preview-fidelity spec and end-to-end feature spec

**Files:**
- Create: `spec/features/work_packages/import_spec.rb`

This is the highest-value spec in the suite, per the design spec's Testing section: it is what stops the preview from silently drifting from creation as `SetAttributesService` evolves, and it is a direct regression test for the `manage_subtasks`/`assign_versions` permission dependencies from Task 8.

**Interfaces:**
- Consumes everything built in Tasks 1–10 through the actual HTTP/browser surface — no new production code.

- [ ] **Step 1: Write the feature spec**

```ruby
# spec/features/work_packages/import_spec.rb
require "spec_helper"

RSpec.describe "Markdown work package import", :js do
  let(:project) { create(:project) }
  let!(:strategic_initiative) { create(:type, name: "Strategic Initiative", projects: [project]) }
  let!(:objective) { create(:type, name: "Objective", projects: [project]) }
  let!(:key_result) { create(:type, name: "Key Result", projects: [project]) }
  let!(:task_type) { create(:type_task, name: "Task", projects: [project]) }
  let!(:organizational_unit_field) do
    create(:custom_field, name: "Organizational Unit", field_format: "department",
                          types: [objective, key_result])
  end
  let!(:marketing) { create(:group, lastname: "Marketing", organizational_unit: true) }

  let(:user) do
    create(:user, member_with_permissions: %i[view_work_packages add_work_packages manage_subtasks
                                              assign_versions import_work_packages])
  end

  let(:document) { <<~MD }
    # Strategic Initiative: Subscription Growth

    ## Objective: Increase subscriber retention
    - Organizational Unit: Marketing

    ### Key Result: Increase annual renewals from 65% to 75%

    #### Task: Rework the renewal reminder sequence
  MD

  before { login_as(user) }

  it "previews then creates the full hierarchy" do
    visit new_project_work_packages_import_path(project)
    fill_in "source", with: document
    click_button "Preview"

    expect(page).to have_text("Strategic Initiative")
    expect(page).to have_text("Subscription Growth")
    expect(page).to have_text("Marketing")
    expect(page).not_to have_selector(".work-package-import-preview--error")

    click_button "Create work packages"

    expect(page).to have_text("Status: succeeded")
    expect(WorkPackage.where(project:).count).to eq(4)

    initiative = WorkPackage.find_by(subject: "Subscription Growth")
    obj = WorkPackage.find_by(subject: "Increase subscriber retention")
    kr = WorkPackage.find_by(subject: "Increase annual renewals from 65% to 75%")
    task = WorkPackage.find_by(subject: "Rework the renewal reminder sequence")

    expect(obj.parent).to eq(initiative)
    expect(kr.parent).to eq(obj)
    expect(task.parent).to eq(kr)
  end

  it "fails to import the same document without manage_subtasks or assign_versions" do
    restricted_user = create(:user, member_with_permissions: %i[view_work_packages add_work_packages import_work_packages])
    login_as(restricted_user)

    run = create(:work_packages_import_run, project:, user: restricted_user, source: document)
    perform_enqueued_jobs { WorkPackages::Import::CreateJob.perform_later(import_run: run) }
    run.reload

    expect(run).to be_failed
  end
end

RSpec.describe "Preview fidelity", type: :request do
  let(:project) { create(:project) }
  let!(:task_type) { create(:type_task, name: "Task", projects: [project]) }
  let(:user) { create(:user, member_with_permissions: %i[view_work_packages add_work_packages
                                                          manage_subtasks assign_versions import_work_packages]) }
  let(:document) { "# Task: Rework the renewal reminder sequence\n" }

  before { login_as(user) }

  it "creates a work package matching the previewed attributes, except computed fields" do
    document_result = WorkPackages::Import::OutlineParser.call(document)
    previewed_row = WorkPackages::Import::Resolver.new(project:, user:).call(document_result.result).result.first

    run = create(:work_packages_import_run, project:, user:, source: document)
    perform_enqueued_jobs { WorkPackages::Import::CreateJob.perform_later(import_run: run) }
    run.reload

    created = WorkPackage.find(run.created_work_package_ids.first)

    expect(created.subject).to eq(previewed_row.work_package.subject)
    expect(created.type_id).to eq(previewed_row.work_package.type_id)
    expect(created.status_id).to eq(previewed_row.work_package.status_id)
    expect(created.priority_id).to eq(previewed_row.work_package.priority_id)
    # derived_done_ratio / derived_estimated_hours / derived_remaining_hours and any
    # type-pattern-driven subject are the only fields expected to differ — none apply
    # to this plain Task, so every previewed attribute above matches exactly.
  end
end
```

- [ ] **Step 2: Run and fix whatever breaks**

```bash
bundle exec rspec spec/features/work_packages/import_spec.rb
```

This is the integration point for every earlier task's assumptions — expect to fix small mismatches here: exact button/field labels from Task 8's `new.html.erb`, the exact route helper names confirmed in Task 8 Step 2, and factory trait names. Iterate until all examples pass; do not weaken an assertion to make it pass without understanding why it failed first (per `superpowers:systematic-debugging` if a failure isn't immediately obvious).

Expected once green: 3 examples, 0 failures.

- [ ] **Step 3: Run the full new-code test suite together as a final check**

```bash
bundle exec rspec spec/models/work_packages/import_run_spec.rb \
                   spec/services/work_packages/import/ \
                   spec/components/work_packages/import/ \
                   spec/workers/work_packages/import/ \
                   spec/controllers/work_packages/imports_controller_spec.rb \
                   spec/features/work_packages/import_spec.rb
```

Expected: all green, no order-dependent failures.

- [ ] **Step 4: Commit**

```bash
git add spec/features/work_packages/import_spec.rb
git commit -m "test(import): add preview-fidelity and end-to-end feature specs"
```
