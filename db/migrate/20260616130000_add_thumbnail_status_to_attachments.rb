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
# See COPYRIGHT and LICENSE files for more details.
#++

# Tracks the derivation state of an attachment's thumbnail so the API can gate
# the thumbnail link on a cheap column read (no per-attachment disk stat during
# list serialization) and the lazy-generation path can avoid retrying files that
# are unsupported or have already failed.
#
# Values: nil (not yet considered / non-thumbnailable), "pending", "ready",
# "unsupported", "error". See attachment_thumbnail_design.md §10.
class AddThumbnailStatusToAttachments < ActiveRecord::Migration[8.1]
  def change
    add_column :attachments, :thumbnail_status, :string, null: true, default: nil
  end
end
