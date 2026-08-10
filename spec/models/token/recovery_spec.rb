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

RSpec.describe Token::Recovery do
  let(:user) { create(:user) }

  describe "validity_time" do
    context "without a channel marker (email / self-service flow)" do
      it "expires after EMAIL_VALIDITY" do
        token = described_class.create!(user_id: user.id)

        expect(token.expires_on).to be_within(1.second).of(described_class::EMAIL_VALIDITY.from_now)
      end
    end

    context "with the chat_link channel marker (admin-generated flow)" do
      it "expires after CHAT_LINK_VALIDITY" do
        token = described_class.create!(user_id: user.id, data: { channel: described_class::CHANNEL_CHAT_LINK })

        expect(token.expires_on).to be_within(1.second).of(described_class::CHAT_LINK_VALIDITY.from_now)
      end
    end

    context "with an unrelated data payload" do
      it "still expires after EMAIL_VALIDITY" do
        token = described_class.create!(user_id: user.id, data: { channel: "something_else" })

        expect(token.expires_on).to be_within(1.second).of(described_class::EMAIL_VALIDITY.from_now)
      end
    end
  end

  it "EMAIL_VALIDITY is longer than CHAT_LINK_VALIDITY" do
    expect(described_class::EMAIL_VALIDITY).to be > described_class::CHAT_LINK_VALIDITY
  end
end
