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

module Attachments
  # Generates an attachment thumbnail off the request path. Enqueued on upload
  # (see Attachment#enqueue_thumbnail_generation) and re-runnable via the
  # attachments:generate_thumbnails_where_missing rake task. Idempotent: it skips
  # attachments that already have a thumbnail on disk.
  class GenerateThumbnailJob < ApplicationJob
    queue_with_priority :low

    def perform(attachment_id)
      attachment = Attachment.find_by(id: attachment_id)
      return unless attachment
      return unless attachment.thumbnailable?

      # Never generate for content that hasn't cleared virus scanning; mirrors
      # the access gating the content/thumbnail endpoints enforce.
      return if attachment.status_quarantined? || attachment.pending_virus_scan?

      return if already_generated?(attachment)

      attachment.generate_thumbnail!
    end

    private

    def already_generated?(attachment)
      attachment.thumbnail_ready? && File.exist?(attachment.thumbnail_path)
    end
  end
end
