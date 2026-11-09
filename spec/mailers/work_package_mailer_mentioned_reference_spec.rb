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

RSpec.describe WorkPackageMailer do
  describe "#mentioned" do
    shared_let(:view_role) { create(:project_role, permissions: %i[view_work_packages]) }
    shared_let(:shared_project) { create(:project, public: false) }
    shared_let(:private_project) { create(:project, public: false, name: "Orchid private project") }
    shared_let(:author) do
      create(:user, member_with_roles: { shared_project => view_role, private_project => view_role })
    end
    shared_let(:recipient) { create(:user, member_with_roles: { shared_project => view_role }) }
    shared_let(:visible_recipient) do
      create(:user, member_with_roles: { shared_project => view_role, private_project => view_role })
    end
    shared_let(:work_package) { create(:work_package, project: shared_project, subject: "Shared topic") }

    let(:journal) do
      create(:work_package_journal,
             journable: work_package,
             user: author,
             version: work_package.journals.maximum(:version).to_i + 1,
             notes: "please look at project##{private_project.id}")
    end

    # The references in the notes are resolved for the person receiving the mail, not for its author.
    it "does not expand a reference to something the recipient cannot see" do
      body = described_class.mentioned(recipient, journal).html_part.body.to_s

      expect(body).to include("project##{private_project.id}")
      expect(body).not_to include(private_project.name)
    end

    it "expands the reference when the recipient can see it" do
      body = described_class.mentioned(visible_recipient, journal).html_part.body.to_s

      expect(body).to include(private_project.name)
    end
  end
end
