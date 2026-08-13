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

module RecurringMeetings
  class DeleteService < ::BaseServices::Delete
    protected

    def default_contract_class
      Meetings::DeleteContract
    end

    def after_validate(call)
      # A queued batched update mail must not arrive after the cancellation mail
      SendUpdatedNotificationJob.delete_jobs(model)

      # Removing the series from participants' calendars always notifies — the mute
      # toggle does not apply. A draft series has never sent invitations.
      send_cancellation_mail(model) unless model.template.draft?

      call
    end

    def send_cancellation_mail(meeting)
      meeting.template.participants.where(invited: true).find_each do |participant|
        MeetingMailer
          .cancelled_series(meeting, participant.user, User.current)
          .deliver_now
      rescue StandardError => e
        Rails.logger.error do
          "Failed to deliver recurring meeting cancellation for series #{meeting.id} to #{participant.user.mail}: #{e.message}"
        end
      end
    end
  end
end
