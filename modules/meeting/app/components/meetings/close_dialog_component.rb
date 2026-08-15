# frozen_string_literal: true

#-- copyright
# OpenProject is an open source project management software.
# Copyright (C) the OpenProject GmbH
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License version 3.
#++

module Meetings
  class CloseDialogComponent < ApplicationComponent
    include ApplicationHelper
    include OpTurbo::Streamable

    def initialize(meeting:)
      super

      @meeting = meeting
      @project = meeting.project
    end

    private

    def id = "close-meeting-dialog"

    def eligible_for_series_close?
      @meeting.eligible_for_series_close?
    end
  end
end
