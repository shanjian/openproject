#-- copyright
# OpenProject is an open source project management software.
# Copyright (C) the OpenProject GmbH
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License version 3.
#
# OpenProject is a fork of ChiliProject, which is a fork of Redmine. The copyright follows:
# Copyright (C) 2006-2013 Jean-Philippe Lang
# Copyright (C) 2010-2013 the ChiliProject Team
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
#
# See COPYRIGHT and LICENSE files for more details.
#++

require_relative "../../../../spec_helper"

RSpec.describe OpenProject::GithubIntegration::NotificationHandler::Helper do
  subject(:handler) { Class.new.include(described_class).new }

  before do
    allow(Setting).to receive(:host_name).and_return("example.net")
  end

  describe "#extract_work_package_ids" do
    it "returns an empty array for an empty source" do
      expect(handler.extract_work_package_ids("")).to eq([])
    end

    it "returns an empty array for a null source" do
      expect(handler.extract_work_package_ids(nil)).to eq([])
    end

    it "finds a work package by code" do
      source = "Blabla\nOP#1234\n"
      expect(handler.extract_work_package_ids(source)).to eq([1234])
    end

    it "finds a plain work package url" do
      source = 'Blabla\nhttps://example.net/work_packages/234\n'
      expect(handler.extract_work_package_ids(source)).to eq([234])
    end

    it "finds a work package url in markdown link syntax" do
      source = 'Blabla\n[WP 234](https://example.net/work_packages/234)\n'
      expect(handler.extract_work_package_ids(source)).to eq([234])
    end

    it "finds multiple work package urls" do
      source = "I reference https://example.net/work_packages/434\n and Blabla\n[WP 234](https://example.net/wp/234)\n"
      expect(handler.extract_work_package_ids(source)).to eq([434, 234])
    end

    it "finds multiple occurrences of a work package only once" do
      source = "I reference https://example.net/work_packages/434\n and Blabla\n[WP 234](https://example.net/work_packages/434)\n"
      expect(handler.extract_work_package_ids(source)).to eq([434])
    end
  end

  describe "#find_visible_work_packages" do
    let(:user) { build_stubbed(:user) }
    let(:visible_wp) { instance_double(WorkPackage, project: :project_with_permissions) }
    let(:invisible_wp) { instance_double(WorkPackage, project: :project_without_permissions) }

    shared_examples_for "it finds visible work packages" do
      subject(:find_visible_work_packages) { handler.find_visible_work_packages(ids, user) }

      before do
        allow(WorkPackage).to receive(:includes).and_return(WorkPackage)
        allow(WorkPackage).to receive(:where).with(id: ids).and_return(work_packages)

        mock_permissions_for(user) do |mock|
          mock.allow_in_project :add_work_package_comments, project: :project_with_permissions
        end
      end

      it "finds work packages visible to the user" do
        expect(find_visible_work_packages).to eql(expected)
      end
    end

    describe "should find an existing work package" do
      let(:work_packages) { [visible_wp] }
      let(:ids) { [0] }
      let(:expected) { work_packages }

      it_behaves_like "it finds visible work packages"
    end

    describe "should not find a non-existing work package" do
      let(:work_packages) { [invisible_wp] }
      let(:ids) { [0] }
      let(:expected) { [] }

      it_behaves_like "it finds visible work packages"
    end

    describe "should find multiple existing work packages" do
      let(:work_packages) { [visible_wp, visible_wp] }
      let(:ids) { [0, 1] }
      let(:expected) { work_packages }

      it_behaves_like "it finds visible work packages"
    end

    describe "should not find work package which the user shall not see" do
      let(:work_packages) { [visible_wp, invisible_wp, visible_wp, invisible_wp] }
      let(:ids) { [0, 1, 2, 3] }
      let(:expected) { [visible_wp, visible_wp] }

      it_behaves_like "it finds visible work packages"
    end
  end

  describe "#find_branch_work_packages" do
    subject(:found) { handler.find_branch_work_packages(branch_name, user) }

    shared_let(:user) { create(:admin) }
    shared_let(:bug_type) { create(:type, name: "Bug") }
    shared_let(:story_type) { create(:type, name: "User story") }
    shared_let(:bug) { create(:work_package, type: bug_type) }
    shared_let(:story) { create(:work_package, type: story_type) }

    context "with a branch following the type/id-title convention" do
      let(:branch_name) { "bug/#{bug.id}-fix-the-crash" }

      it { is_expected.to contain_exactly(bug) }
    end

    context "with a type whose name is sanitized the way the git snippets do" do
      let(:branch_name) { "user-story/#{story.id}-as-a-user" }

      it { is_expected.to contain_exactly(story) }
    end

    context "with a branch following the convention, in a different case" do
      let(:branch_name) { "BUG/#{bug.id}-Fix" }

      it { is_expected.to contain_exactly(bug) }
    end

    context "with a branch that has nothing after the id's dash" do
      let(:branch_name) { "bug/#{bug.id}-" }

      it { is_expected.to contain_exactly(bug) }
    end

    context "with a branch whose type does not match the work package's" do
      let(:branch_name) { "feature/#{bug.id}-fix-the-crash" }

      it { is_expected.to be_empty }
    end

    context "with a branch that has the id but not the dash after it" do
      let(:branch_name) { "bug/#{bug.id}" }

      it { is_expected.to be_empty }
    end

    context "with a branch whose id only happens to be inside of its name" do
      let(:branch_name) { "bug/x#{bug.id}-fix" }

      it { is_expected.to be_empty }
    end

    context "with a branch that has no type prefix" do
      let(:branch_name) { "#{bug.id}-fix-the-crash" }

      it { is_expected.to be_empty }
    end

    context "with a branch mentioning a work package with OP#" do
      let(:branch_name) { "hotfix-OP##{bug.id}" }

      it { is_expected.to contain_exactly(bug) }
    end

    context "with a branch mentioning one work package by convention and another by OP#" do
      let(:branch_name) { "bug/#{bug.id}-also-OP##{story.id}" }

      it { is_expected.to contain_exactly(bug, story) }
    end

    context "with a branch mentioning a work package both ways" do
      let(:branch_name) { "bug/#{bug.id}-OP##{bug.id}" }

      it "finds it once" do
        expect(found).to eq([bug])
      end
    end

    context "with a branch that references no work package" do
      let(:branch_name) { "main" }

      it { is_expected.to be_empty }
    end

    context "with a work package the user is not allowed to comment on" do
      let(:user) { create(:user) }
      let(:branch_name) { "bug/#{bug.id}-fix-the-crash" }

      it { is_expected.to be_empty }
    end
  end
end
