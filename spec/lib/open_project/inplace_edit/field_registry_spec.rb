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

require "rails_helper"

RSpec.describe OpenProject::InplaceEdit::FieldRegistry do
  subject(:registry) { described_class.new }

  let(:rich_text_component) { Class.new }

  describe "#register" do
    it "registers a field component for an attribute" do
      registry.register(:description, rich_text_component)

      expect(registry.fetch(:description)).to eq(rich_text_component)
    end
  end

  describe "#fetch" do
    it "returns the registered component for the attribute" do
      registry.register(:description, rich_text_component)

      expect(registry.fetch(:description)).to eq(rich_text_component)
    end

    it "falls back to TextInputComponent if attribute is not registered" do
      expect(registry.fetch(:unknown))
        .to eq(OpenProject::Common::InplaceEditFields::TextInputComponent)
    end

    it "normalizes attribute names to strings" do
      registry.register("description", rich_text_component)

      expect(registry.fetch(:description)).to eq(rich_text_component)
    end
  end

  describe "#registered? and #editable?" do
    before { registry.register(:description, rich_text_component) }

    it "accepts a registered attribute, as symbol or string" do
      expect(registry).to be_registered(:description)
      expect(registry).to be_registered("description")
      expect(registry).to be_editable(:description)
    end

    it "rejects attributes that are not registered, even if the model has such a method" do
      %w[destroy name touch to_json custom_field_1 remove_owned_labels].each do |name|
        expect(registry).not_to be_registered(name)
        expect(registry).not_to be_editable(name)
      end
    end
  end
end
