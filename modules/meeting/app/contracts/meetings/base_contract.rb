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

module Meetings
  class BaseContract < ::ModelContract
    def self.model
      Meeting
    end

    attribute :title
    attribute :author_id
    attribute :project_id
    attribute :location
    attribute :duration
    attribute :state do
      validate_state_not_transitioning_cancelled
    end
    attribute :start_date
    attribute :start_time
    attribute :start_time_hour
    attribute :template
    attribute :notify
    attribute :sharing do
      validate_sharing_only_on_onetime_templates
    end

    private

    # The cancelled state is owned by Meetings::CancelService/RestoreService, which
    # stamp state_before_cancellation and send the mandatory mails. Generic writes
    # in either direction would silently break that invariant.
    def validate_state_not_transitioning_cancelled
      return unless model.state_changed?

      if model.state == "cancelled" || model.state_was == "cancelled"
        errors.add :state, :invalid
      end
    end

    def validate_sharing_only_on_onetime_templates
      return if model.onetime_template?

      errors.add :sharing, :not_allowed if model.sharing.present?
    end
  end
end
