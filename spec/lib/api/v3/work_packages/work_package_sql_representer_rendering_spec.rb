# frozen_string_literal: true

#  OpenProject is an open source project management software.
#  Copyright (C) the OpenProject GmbH
#
#  This program is free software; you can redistribute it and/or
#  modify it under the terms of the GNU General Public License version 3.
#
#  OpenProject is a fork of ChiliProject, which is a fork of Redmine. The copyright follows:
#  Copyright (C) 2006-2013 Jean-Philippe Lang
#  Copyright (C) 2010-2013 the ChiliProject Team
#
#  This program is free software; you can redistribute it and/or
#  modify it under the terms of the GNU General Public License
#  as published by the Free Software Foundation; either version 2
#  of the License, or (at your option) any later version.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with this program; if not, write to the Free Software
#  Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
#
#  See COPYRIGHT and LICENSE files for more details.

require "spec_helper"

RSpec.describe API::V3::WorkPackages::WorkPackageSqlRepresenter, "rendering" do
  include API::V3::Utilities::PathHelper

  subject(:json) do
    API::V3::Utilities::SqlRepresenterWalker
      .new(scope,
           current_user:,
           url_query: { select: })
      .walk(described_class)
      .to_json
  end

  let(:scope) do
    WorkPackage
      .where(id: rendered_work_package.id)
  end

  let(:rendered_work_package) do
    create(:work_package,
           project:,
           type:,
           assigned_to: assignee,
           author:,
           responsible:)
  end
  let(:project) { create(:project, types: [type]) }
  let(:type) { create(:type, is_milestone:) }
  let(:is_milestone) { false }
  let(:assignee) { nil }
  let(:author) { create(:user) }
  let(:responsible) { nil }

  let(:select) { { "*" => {} } }

  current_user do
    create(:user)
  end

  context "when rendering all supported properties" do
    context "for a work_package" do
      let(:expected) do
        {
          _type: "WorkPackage",
          id: rendered_work_package.id,
          subject: rendered_work_package.subject,
          dueDate: rendered_work_package.due_date,
          startDate: rendered_work_package.start_date,
          storyPoints: nil,
          estimatedHours: nil,
          _links: {
            self: {
              href: api_v3_paths.work_package(rendered_work_package.id),
              title: rendered_work_package.subject
            },
            project: {
              href: api_v3_paths.project(project.id),
              title: project.name
            },
            assignee: {
              href: nil
            },
            responsible: {
              href: nil
            },
            author: {
              href: api_v3_paths.user(author.id),
              title: author.name
            },
            status: {
              href: api_v3_paths.status(rendered_work_package.status.id),
              title: rendered_work_package.status.name
            },
            type: {
              href: api_v3_paths.type(type.id),
              title: type.name
            },
            priority: {
              href: api_v3_paths.priority(rendered_work_package.priority.id),
              title: rendered_work_package.priority.name
            },
            epic: {
              href: nil
            }
          }
        }
      end

      it "renders as expected" do
        expect(json)
          .to be_json_eql(expected.to_json)
      end
    end

    context "for a milestone work_package" do
      let(:is_milestone) { true }
      let(:expected) do
        {
          _type: "WorkPackage",
          id: rendered_work_package.id,
          subject: rendered_work_package.subject,
          date: rendered_work_package.start_date,
          storyPoints: nil,
          estimatedHours: nil,
          _links: {
            self: {
              href: api_v3_paths.work_package(rendered_work_package.id),
              title: rendered_work_package.subject
            },
            project: {
              href: api_v3_paths.project(project.id),
              title: project.name
            },
            assignee: {
              href: nil
            },
            responsible: {
              href: nil
            },
            author: {
              href: api_v3_paths.user(author.id),
              title: author.name
            },
            status: {
              href: api_v3_paths.status(rendered_work_package.status.id),
              title: rendered_work_package.status.name
            },
            type: {
              href: api_v3_paths.type(type.id),
              title: type.name
            },
            priority: {
              href: api_v3_paths.priority(rendered_work_package.priority.id),
              title: rendered_work_package.priority.name
            },
            epic: {
              href: nil
            }
          }
        }
      end

      it "renders as expected" do
        expect(json).to be_json_eql(expected.to_json)
      end
    end
  end

  shared_examples_for "principal link" do |link_name, only_user: false|
    let(:select) { { link_name => {} } }

    context "with a user" do
      let(:principal_object) { create(:user) }

      let(:expected) do
        {
          _links: {
            link_name => {
              href: api_v3_paths.user(principal_object.id),
              title: principal_object.name
            }
          }
        }
      end

      it "renders as expected" do
        expect(json)
          .to be_json_eql(expected.to_json)
      end
    end

    unless only_user
      context "with a group" do
        let(:principal_object) { create(:group) }

        let(:expected) do
          {
            _links: {
              link_name => {
                href: api_v3_paths.group(principal_object.id),
                title: principal_object.name
              }
            }
          }
        end

        it "renders as expected" do
          expect(json)
            .to be_json_eql(expected.to_json)
        end
      end

      context "with a placeholder user" do
        let(:principal_object) { create(:placeholder_user) }

        let(:expected) do
          {
            _links: {
              link_name => {
                href: api_v3_paths.placeholder_user(principal_object.id),
                title: principal_object.name
              }
            }
          }
        end

        it "renders as expected" do
          expect(json)
            .to be_json_eql(expected.to_json)
        end
      end
    end
  end

  describe "assignee link" do
    it_behaves_like "principal link", "assignee" do
      let(:assignee) { principal_object }
    end
  end

  describe "responsible link" do
    it_behaves_like "principal link", "responsible" do
      let(:responsible) { principal_object }
    end
  end

  describe "author link" do
    it_behaves_like "principal link", "author", only_user: true do
      let(:author) { principal_object }
    end
  end

  describe "priority link" do
    let(:select) { { "priority" => {} } }

    context "with a priority" do
      let(:expected) do
        {
          _links: {
            priority: {
              href: api_v3_paths.priority(rendered_work_package.priority.id),
              title: rendered_work_package.priority.name
            }
          }
        }
      end

      it "renders the priority link" do
        expect(json).to be_json_eql(expected.to_json)
      end
    end

    context "without a priority" do
      before do
        rendered_work_package.update_column(:priority_id, nil)
      end

      let(:expected) do
        {
          _links: {
            priority: {
              href: nil
            }
          }
        }
      end

      it "renders a null priority link" do
        expect(json).to be_json_eql(expected.to_json)
      end
    end
  end

  describe "story points and estimated hours properties" do
    let(:select) { { "storyPoints" => {}, "estimatedHours" => {} } }

    before do
      rendered_work_package.update_columns(story_points: 5, estimated_hours: 7.5)
    end

    it "renders the raw values" do
      expect(json).to be_json_eql({ storyPoints: 5, estimatedHours: 7.5 }.to_json)
    end
  end

  describe "epic link" do
    let(:select) { { "epic" => {} } }

    context "with an epic" do
      let(:epic) { create(:work_package, project:, subject: "Parent epic") }
      let(:expected) do
        {
          _links: {
            epic: {
              href: api_v3_paths.work_package(epic.id),
              title: "Parent epic"
            }
          }
        }
      end

      before { rendered_work_package.update_column(:epic_id, epic.id) }

      it "renders the epic link with the epic's subject" do
        expect(json).to be_json_eql(expected.to_json)
      end
    end

    context "without an epic" do
      let(:expected) do
        {
          _links: {
            epic: {
              href: nil
            }
          }
        }
      end

      it "renders a null epic link" do
        expect(json).to be_json_eql(expected.to_json)
      end
    end

    # Regression: the epic subject is joined from a derived table exposing only
    # (id, subject). A bare work_packages self-join would add a second
    # work_packages instance and make the unqualified assigned_to_id / author_id /
    # responsible_id references in the sibling user links ambiguous
    # (PG::AmbiguousColumn), which 500-ed every board list.
    context "when selected together with the user links (board card select)" do
      let(:select) { { "epic" => {}, "assignee" => {}, "author" => {}, "responsible" => {} } }
      let(:assignee) { create(:user) }
      let(:responsible) { create(:user) }

      it "renders without raising an ambiguous-column error" do
        expect { json }.not_to raise_error
      end
    end
  end
end
