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

module WorkPackages
  module Import
    # @logical_path OpenProject/WorkPackages/Import
    class PreviewComponentPreview < ViewComponent::Preview
      def default
        node = WorkPackages::Import::OutlineParser::Node.new(level: 1, type_name: "Key Result",
                                                             subject: "Increase annual renewals from 65% to 75%",
                                                             attributes: {}, description: "", source_line: 6, parent_index: nil)
        row = WorkPackages::Import::Resolver::ResolvedRow.new(
          node:, work_package: WorkPackage.new(subject: node.subject),
          attribute_matches: [{ label: "Accountable", formatted: "Jane Doe (jane.doe@example.com)" },
                              { label: "Baseline", formatted: "65" }],
          errors: []
        )
        render WorkPackages::Import::PreviewComponent.new(rows: [row])
      end
    end
  end
end
