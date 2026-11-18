# frozen_string_literal: true

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

require "spec_helper"

RSpec.describe GithubBranch do
  describe "Associations" do
    it { is_expected.to have_and_belong_to_many(:work_packages) }
  end

  describe "Validations" do
    it { is_expected.to validate_presence_of :name }
    it { is_expected.to validate_presence_of :github_html_url }
    it { is_expected.to validate_presence_of :repository }
    it { is_expected.to validate_presence_of :github_updated_at }

    context "when it is a valid branch" do
      let(:branch) { build(:github_branch) }

      it { expect(branch).to be_valid }
    end
  end

  describe ".without_work_package" do
    subject { described_class.without_work_package }

    let(:branch) { create(:github_branch, work_packages:) }
    let(:work_packages) { [] }

    before { branch }

    it { is_expected.to contain_exactly(branch) }

    context "when the branch is linked to a work package" do
      let(:work_packages) { create_list(:work_package, 1) }

      it { is_expected.to be_empty }
    end
  end

  describe ".build_html_url" do
    it "keeps the convention's slashes as path separators" do
      expect(described_class.build_html_url("https://github.com/user/repo", "task/42-fix-thing"))
        .to eq("https://github.com/user/repo/tree/task/42-fix-thing")
    end

    it "escapes URL-significant characters so a '#' does not become a fragment" do
      expect(described_class.build_html_url("https://github.com/user/repo", "hotfix-OP#42"))
        .to eq("https://github.com/user/repo/tree/hotfix-OP%2342")
    end
  end

  describe ".find_by_github_identifiers" do
    shared_let(:branch) { create(:github_branch) }

    it "raises an ArgumentError when no url is provided" do
      expect { described_class.find_by_github_identifiers(url: nil) }
        .to raise_error(ArgumentError, "needs an url")
    end

    context "when the url matches" do
      it "finds the branch" do
        expect(described_class.find_by_github_identifiers(url: branch.github_html_url)).to eql(branch)
      end
    end

    context "when the url does not match" do
      it "is nil" do
        expect(described_class.find_by_github_identifiers(url: "#{branch.github_html_url}zzz")).to be_nil
      end
    end

    context "when the url does not match but initialize is true" do
      subject(:finder) do
        described_class.find_by_github_identifiers(url: "#{branch.github_html_url}zzz", initialize: true)
      end

      it { is_expected.to be_a(described_class) }
      it { is_expected.to be_new_record }

      it "has the url initialized" do
        expect(finder.github_html_url).to eq("#{branch.github_html_url}zzz")
      end
    end

    context "when two branches in different repositories share a name" do
      # Only the URL (which embeds the repository) is globally unique, so
      # same-named branches must stay distinct.
      shared_let(:other_branch) do
        create(:github_branch,
               name: branch.name,
               github_html_url: "https://github.com/other_user/other_repo/tree/#{branch.name}")
      end

      it "finds each branch by its own url" do
        expect(described_class.find_by_github_identifiers(url: branch.github_html_url)).to eql(branch)
        expect(described_class.find_by_github_identifiers(url: other_branch.github_html_url)).to eql(other_branch)
      end
    end
  end

  describe "uniqueness of the url" do
    let!(:branch) { create(:github_branch) }

    it "is enforced by the database" do
      expect { create(:github_branch, github_html_url: branch.github_html_url) }
        .to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe "work package association" do
    let(:work_package) { create(:work_package) }
    let(:branch) { create(:github_branch, work_packages: [work_package]) }

    it "is reachable from the work package" do
      expect(work_package.github_branches).to contain_exactly(branch)
    end

    it "is dropped from the work package's list without deleting the branch when the work package is destroyed" do
      branch
      work_package.destroy!

      expect(described_class.find(branch.id).work_packages).to be_empty
    end
  end
end
