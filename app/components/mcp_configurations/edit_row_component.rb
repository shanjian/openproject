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
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA.
#
# See COPYRIGHT and LICENSE files for more details.
#++

module McpConfigurations
  class EditRowComponent < OpPrimer::BorderBoxRowComponent
    def name
      safe_join([name_text, (modifies_data_label if modifies_data?)].compact, " ")
    end

    def title
      render(
        Primer::Alpha::TextField.new(
          name: "mcp_configurations[#{config.identifier}][title]",
          label: McpConfiguration.human_attribute_name(:title),
          visually_hide_label: true,
          value: config.title,
          data: { test_selector: "mcp-configuration--title-input-#{config.identifier}" }
        )
      )
    end

    def description
      render(
        Primer::Alpha::TextArea.new(
          name: "mcp_configurations[#{config.identifier}][description]",
          label: McpConfiguration.human_attribute_name(:description),
          visually_hide_label: true,
          value: config.description,
          rows: 4,
          data: { test_selector: "mcp-configuration--description-input-#{config.identifier}" }
        )
      )
    end

    def enabled
      render(
        Primer::Alpha::CheckBox.new(
          name: "mcp_configurations[#{config.identifier}][enabled]",
          label: McpConfiguration.human_attribute_name(:enabled),
          visually_hide_label: true,
          checked: config.enabled,
          test_selector: "mcp-configuration--enabled-input-#{config.identifier}"
        )
      )
    end

    private

    def config
      model
    end

    def name_text
      render(
        Primer::Beta::Text.new(
          font_weight: :bold,
          data: { test_selector: "mcp-configuration--config-row-name" }
        )
      ) { config.identifier.split("/", 2).last }
    end

    # Unticking a tool is how an administrator stops assistants writing, so say which rows write.
    # A resource, or a row whose tool is no longer registered, is never marked: only a tool that is
    # known, and does not declare itself read-only, is.
    def modifies_data?
      tool = McpTools.tools_by_name[config.identifier]

      tool.present? && !tool.read_annotations[:read_only_hint]
    end

    def modifies_data_label
      render(
        Primer::Beta::Label.new(
          scheme: :attention,
          title: I18n.t("mcp_configurations.edit_row_component.modifies_data_title"),
          data: { test_selector: "mcp-configuration--modifies-data-badge" }
        )
      ) { I18n.t("mcp_configurations.edit_row_component.modifies_data") }
    end
  end
end
