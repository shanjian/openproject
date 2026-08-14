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
  class SidePanel::ParticipantsComponent < ApplicationComponent
    include ApplicationHelper
    include OpTurbo::Streamable
    include OpPrimer::ComponentHelpers

    MAX_SHOWN_PARTICIPANTS = 5

    def wrapper_data_attributes
      {
        controller: "expandable-list"
      }
    end

    def initialize(meeting:)
      super

      @meeting = meeting
      @project = meeting.project
    end

    def elements
      @elements ||= @meeting.participants.sort_by(&:status_sorting_value)
    end

    def count
      @count ||= elements.count
    end

    # Aggregate response counts over invited participants; needs-action and
    # unknown fold into "pending". Zero segments are omitted.
    def response_summary_segments
      @response_summary_segments ||= begin
        # group().count returns enum labels ("needs_action"), not DB values
        counts = @meeting.participants.invited.group(:participation_status).count
        pending = counts.fetch("needs_action", 0) + counts.fetch("unknown", 0)

        [
          ["accepted", counts.fetch("accepted", 0), :success],
          ["tentative", counts.fetch("tentative", 0), :attention],
          ["declined", counts.fetch("declined", 0), :danger],
          ["pending", pending, :subtle]
        ].reject { |_, segment_count, _| segment_count.zero? }
      end
    end

    def current_participant
      return @current_participant if defined?(@current_participant)

      @current_participant = @meeting.participants.invited.find_by(user: User.current)
    end

    # Mirrors MeetingParticipants::RespondService#respondable?
    def respondable?
      (@meeting.open? || @meeting.in_progress?) &&
        !@meeting.template? &&
        current_participant.present?
    end

    def respond_button(flex, status:, color:)
      selected = current_participant.participation_status == status

      flex.with_column(mr: 2) do
        render(Primer::Beta::Button.new(
                 tag: :a,
                 size: :small,
                 scheme: selected ? :default : :invisible,
                 href: respond_href(status),
                 test_selector: "meeting-respond-#{status}",
                 data: respond_button_data
               )) do |button|
          button.with_leading_visual_icon(icon: :check, color:) if selected
          t("meeting_participant.participation_status.#{status}").capitalize
        end
      end
    end

    # One-off meetings respond directly; occurrences go through the scope dialog
    def respond_href(status)
      if @meeting.recurring?
        respond_dialog_project_meeting_path(@project, @meeting, status:)
      else
        respond_project_meeting_path(@project, @meeting, status:)
      end
    end

    def respond_button_data
      if @meeting.recurring?
        { controller: "async-dialog" }
      else
        { turbo_method: :post, turbo_stream: true }
      end
    end

    def render_participant(participant)
      flex_layout(align_items: :center) do |flex|
        flex.with_column(classes: "ellipsis") do
          render(Users::AvatarComponent.new(user: participant.user,
                                            size: :medium,
                                            classes: "op-principal_flex"))
        end
        render_participant_state(participant, flex)
      end
    end

    def render_participant_state(participant, flex) # rubocop:disable Metrics/AbcSize
      if participant.attended?
        flex.with_column(ml: 1) do
          render(Primer::Beta::Text.new(font_size: :small, color: :subtle)) { t("description_attended").capitalize }
        end
      elsif participant.participation_accepted?
        flex.with_column(ml: 1) do
          render(Primer::Beta::Text.new(font_size: :small, color: :success)) { t("meeting_participant.participation_status.accepted").capitalize }
        end
      elsif participant.participation_declined?
        flex.with_column(ml: 1) do
          render(Primer::Beta::Text.new(font_size: :small, color: :danger)) { t("meeting_participant.participation_status.declined").capitalize }
        end
      elsif participant.participation_tentative?
        flex.with_column(ml: 1) do
          render(Primer::Beta::Text.new(font_size: :small, color: :attention)) { t("meeting_participant.participation_status.tentative").capitalize }
        end
      end
    end
  end
end
