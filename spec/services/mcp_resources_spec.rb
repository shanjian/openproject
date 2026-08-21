# frozen_string_literal: true

# -- copyright
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
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA.
#
# See COPYRIGHT and LICENSE files for more details.
# ++
require "spec_helper"

RSpec.describe McpResources do
  describe ".register" do
    it "has registered the resources the initializer declares" do
      expect(described_class.all).to include(McpResources::WorkPackage)
    end

    # Registration runs from a to_prepare block so the registry survives code reloading in
    # development, and that block fires more than once per reload cycle. Appending
    # unconditionally duplicates every entry, which is what upstream does.
    it "is a no-op for resources that are already registered" do
      expect { described_class.register(*described_class.all) }
        .not_to change(described_class, :all)
    end

    it "invalidates the memoized #resources_by_name so a newly registered resource is findable" do
      extra = Class.new(described_class::Base) { name "spec_only_resource" }
      described_class.resources_by_name # memoize the lookup before registering

      described_class.register(extra)

      expect(described_class.resources_by_name["resources/spec_only_resource"]).to eq(extra)
    ensure
      described_class.all.delete(extra)
      described_class.register # a no-op registration, to drop the memoized lookup again
    end
  end
end
