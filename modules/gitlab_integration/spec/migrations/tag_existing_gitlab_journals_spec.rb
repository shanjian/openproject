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
require_module_spec_helper
require Rails.root.join("modules/gitlab_integration/db/migrate/20260730000000_tag_existing_gitlab_journals.rb")

RSpec.describe TagExistingGitlabJournals, type: :model do
  subject(:migrate!) { ActiveRecord::Migration.suppress_messages { described_class.migrate(:up) } }

  shared_let(:gitlab_system_user) { create(:admin) }
  shared_let(:work_package) { create(:work_package) }

  # The comments were written in whatever locale was active when the webhook was
  # handled, and the Crowdin translations differ from English in wording, word
  # order and punctuation -- so the migration has to cover every shipped locale,
  # not just English.
  def locales
    %i[en de es fr ja ru zh-CN]
  end

  def gitlab_note(key, locale, **extra)
    I18n.t("gitlab_integration.#{key}",
           locale:,
           repository: "EET Client",
           repository_url: "http://gitlab.example/g/r",
           gitlab_user: "gitlab robot",
           gitlab_user_url: "http://gitlab.example/robot",
           **extra)
  end

  def mr_comment(locale)
    gitlab_note("note_mr_commented_comment", locale,
                mr_number: 3180,
                mr_title: "Update Recipe Article Template",
                mr_url: "http://gitlab.example/g/r/-/merge_requests/3180",
                mr_note: "Blocking: this changes the notFound-driving fetch.")
  end

  def push_comment(locale)
    gitlab_note("push_single_commit_comment_with_ref", locale,
                reference: "refs/heads/develop",
                commit_number: "d8eb784f",
                commit_url: "http://gitlab.example/g/r/-/commit/d8eb784f",
                commit_timestamp: "2026-07-24T19:00:00+00:00",
                commit_note: "OP#82889 Update Recipe Article Template")
  end

  def add_comment(notes)
    work_package.add_journal(user: gitlab_system_user, notes:)
    work_package.save!
    work_package.journals.reload.last
  end

  describe "#up" do
    it "tags GitLab comments written in any shipped locale" do
      journals = locales.index_with { |locale| add_comment(mr_comment(locale)) }

      migrate!

      journals.each do |locale, journal|
        expect(journal.reload.cause)
          .to eq({ "type" => "gitlab_event", "event" => "note" }),
              "expected the #{locale} comment to be tagged, got #{journal.cause.inspect}"
      end
    end

    it "records the event family the comment reports" do
      push = add_comment(push_comment(:de))

      migrate!

      expect(push.reload.cause).to eq("type" => "gitlab_event", "event" => "push")
    end

    it "leaves comments people wrote alone" do
      plain = add_comment("This looks wrong to me, see the merge request.")
      # Quoting a template's label is not enough to be mistaken for one.
      quoting = add_comment("I agree with **Commented in MR:** above")

      migrate!

      expect(plain.reload.cause).to be_blank
      expect(quoting.reload.cause).to be_blank
    end

    it "does not overwrite a cause the journal already carries" do
      work_package.add_journal(user: gitlab_system_user,
                               notes: mr_comment(:en),
                               cause: Journal::CausedBySystemUpdate.new(feature: "some_feature"))
      work_package.save!
      journal = work_package.journals.reload.last

      migrate!

      expect(journal.reload.cause).to include("type" => "system_update")
    end
  end

  describe "#down" do
    it "removes the tag again" do
      journal = add_comment(mr_comment(:es))
      migrate!
      expect(journal.reload.cause).to be_present

      ActiveRecord::Migration.suppress_messages { described_class.migrate(:down) }

      expect(journal.reload.cause).to be_blank
    end
  end
end
