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

require "spec_helper"

RSpec.describe Project, "label governance" do
  shared_let(:field) do
    create(:list_wp_custom_field, name: "Labels", multi_value: true, possible_values: %w[ML-Shared])
  end

  describe "label_prefix" do
    it "accepts a well-formed prefix" do
      expect(build(:project, label_prefix: "AT")).to be_valid
      expect(build(:project, label_prefix: "WEBEXT")).to be_valid
    end

    it "rejects a prefix longer than the fragment allows" do
      # the whole point of anchoring: an unanchored expression matches TOOLONG's first six
      # characters and lets it through
      expect(build(:project, label_prefix: "TOOLONG")).not_to be_valid
    end

    it "rejects a lower case or hyphenated prefix" do
      expect(build(:project, label_prefix: "at")).not_to be_valid
      expect(build(:project, label_prefix: "WEB-EXT")).not_to be_valid
    end

    it "normalises a blank prefix to nil so several projects can have none" do
      first = create(:project, label_prefix: "")
      second = create(:project, label_prefix: "")

      expect(first.label_prefix).to be_nil
      expect(second.label_prefix).to be_nil
    end

    it "refuses to share a prefix between projects" do
      create(:project, label_prefix: "AT")

      expect(build(:project, label_prefix: "AT")).not_to be_valid
    end
  end

  describe "#remove_owned_labels" do
    # `let`, not `shared_let`: these examples destroy the owner, and a memoized record stays
    # marked destroyed for later examples even though the database rolls back.
    let(:owner) { create(:project, label_prefix: "AT") }
    let(:elsewhere) { create(:project, label_prefix: "ADT") }

    def owned_label(value)
      create(:custom_option, custom_field: field, value:, project: owner)
    end

    def tag(work_package, option)
      CustomValue.create!(customized: work_package, custom_field: field, value: option.id.to_s)
    end

    # where(project_id: nil) selects the SYSTEM options, so an unsaved project running
    # before_destroy would delete the shared taxonomy of the whole instance.
    it "does nothing for an unsaved project" do
      field.custom_options.create!(value: "SYS-Kept")
      before = field.custom_options.count

      expect(described_class.new.destroy).to be_truthy

      expect(field.custom_options.reload.count).to eq before
    end

    it "deletes an option nothing else references, along with its values" do
      option = owned_label("AT-Local")
      wp = create(:work_package, project: owner)
      tag(wp, option)

      owner.destroy!

      expect(CustomOption.where(id: option.id)).to be_empty
      expect(CustomValue.where(custom_field: field, value: option.id.to_s)).to be_empty
    end

    it "promotes an option a work package in another project still carries" do
      option = owned_label("AT-Borrowed")
      foreign = create(:work_package, project: elsewhere)
      tag(foreign, option)

      owner.destroy!

      expect(option.reload.project_id).to be_nil
      expect(CustomValue.where(custom_field: field, value: option.id.to_s)).to be_present
    end

    it "succeeds even when the option is the last one on its field" do
      lonely_field = create(:list_wp_custom_field, name: "Lonely", possible_values: %w[Only])
      lonely_field.custom_options.update_all(project_id: owner.id)

      expect { owner.destroy }.not_to raise_error
      expect(described_class.where(id: owner.id)).to be_empty
    end

    # update_all and delete_all skip CustomOption's callbacks, including the touch on its
    # custom_field, so cached option and filter representations would keep serving labels
    # that have been promoted or deleted.
    it "touches the custom field so its caches are invalidated" do
      owned_label("AT-Local")
      before = field.reload.updated_at

      travel(1.second) { owner.destroy! }

      expect(field.reload.updated_at).to be > before
    end

    it "does not delete an unrelated field's value that happens to equal an option id" do
      option = owned_label("AT-Local")
      integer_field = create(:integer_wp_custom_field, name: "Estimate")
      wp = create(:work_package, project: elsewhere)
      collision = CustomValue.create!(customized: wp, custom_field: integer_field, value: option.id.to_s)

      owner.destroy!

      expect(CustomValue.where(id: collision.id)).to be_present
    end
  end
end
