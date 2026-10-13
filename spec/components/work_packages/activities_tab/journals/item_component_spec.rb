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
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA.
#
# See COPYRIGHT and LICENSE files for more details.
#++

require "spec_helper"

RSpec.describe WorkPackages::ActivitiesTab::Journals::ItemComponent, type: :component do
  let(:user) { create(:admin) }
  let(:work_package) { create(:work_package, author: user) }
  let(:cause) { Journal::CausedByMcp.new(tool: "create_work_package_comment") }

  def comment_journal(cause: nil)
    wp = WorkPackage.find(work_package.id)
    User.execute_as(user) { AddWorkPackageNoteService.new(user:, work_package: wp).call("A comment", cause:) }
    Journal.with_sequence_version.find(Journal.where(journable: work_package).order(:version).last.id)
  end

  def render_comment(journal, filter)
    User.current = user
    render_inline(described_class.new(journal:, filter:, grouped_emoji_reactions: {}))
  end

  context "with a comment an AI assistant wrote" do
    let(:journal) { comment_journal(cause:) }

    %i[all only_comments].each do |filter|
      it "labels the comment when showing #{filter}" do
        render_comment(journal, filter)

        expect(page).to have_test_selector("op-journal-assistant-label", text: "AI assistant")
        expect(page).to have_text("A comment")
      end
    end

    it "shows the comment's cause as a change line instead when only changes are shown" do
      render_comment(journal, :only_changes)

      expect(page).to have_text("AI assistant (MCP): added this comment.")
      expect(page).to have_no_test_selector("op-journal-assistant-label")
    end
  end

  context "with a comment a person wrote" do
    let(:journal) { comment_journal }

    %i[all only_comments].each do |filter|
      it "does not label it when showing #{filter}" do
        render_comment(journal, filter)

        expect(page).to have_text("A comment")
        expect(page).to have_no_test_selector("op-journal-assistant-label")
      end
    end
  end
end
