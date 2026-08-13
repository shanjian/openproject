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
require "contracts/shared/model_contract_shared_context"

RSpec.describe Meetings::UpdateContract do
  include_context "ModelContract shared context"

  shared_let(:project) { create(:project) }
  shared_let(:meeting) { create(:meeting, project:) }
  let(:contract) { described_class.new(meeting, user) }

  context "with permission" do
    let(:user) do
      create(:user, member_with_permissions: { project => [:edit_meetings] })
    end

    it_behaves_like "contract is valid"

    context "when setting sharing on a non-template" do
      let(:meeting) { create(:meeting, project:, sharing: nil) }

      before { meeting.sharing = "none" }

      it_behaves_like "contract is invalid", sharing: %i[present not_allowed]
    end

    context "when setting sharing on a onetime template" do
      let(:meeting) { create(:onetime_template, project:, sharing: :none) }

      it_behaves_like "contract is valid"
    end

    context "when writing state to cancelled" do
      before { meeting.state = "cancelled" }

      it_behaves_like "contract is invalid", state: :invalid
    end

    context "when writing state off cancelled" do
      let(:meeting) { create(:meeting, project:, state: "cancelled") }

      before { meeting.state = "open" }

      it_behaves_like "contract is invalid", state: :invalid
    end

    context "when changing state between regular values" do
      before { meeting.state = "in_progress" }

      it_behaves_like "contract is valid"
    end

    context "when lock_version is changed" do
      before do
        allow(meeting).to receive(:lock_version_changed?).and_return(true)
      end

      it_behaves_like "contract is invalid", base: :error_conflict
    end
  end

  context "without permission" do
    let(:user) { build_stubbed(:user) }

    it_behaves_like "contract is invalid", base: :error_unauthorized
  end

  include_examples "contract reuses the model errors" do
    let(:user) { build_stubbed(:user) }
  end
end
