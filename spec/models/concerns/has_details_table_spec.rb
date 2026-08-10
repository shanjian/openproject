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

RSpec.describe HasDetailsTable do
  before(:all) do # rubocop:disable RSpec/BeforeAfterAll
    ActiveRecord::Schema.define do
      create_table :test_widgets, force: true do |t|
        t.string :name
        t.timestamps
      end

      create_table :test_widget_details, force: true do |t|
        t.references :test_widget, null: false, index: { unique: true }
        t.boolean :fancy, default: false, null: false
        t.references :related_widget, foreign_key: { to_table: :test_widgets }
        t.timestamps
      end
    end

    klass = Class.new(ApplicationRecord) { self.table_name = "test_widgets" }
    Object.const_set(:TestWidget, klass)
    klass.include(described_class)
    klass.has_details_table do
      belongs_to :related_widget, class_name: "TestWidget", optional: true

      validates :related_widget, presence: true, if: -> { related_widget_id.present? }
    end
  end

  after(:all) do # rubocop:disable RSpec/BeforeAfterAll
    Object.send(:remove_const, :TestWidgetDetail) if defined?(TestWidgetDetail) # rubocop:disable RSpec/RemoveConst
    Object.send(:remove_const, :TestWidget) if defined?(TestWidget) # rubocop:disable RSpec/RemoveConst

    ActiveRecord::Schema.define do
      drop_table :test_widget_details, if_exists: true
      drop_table :test_widgets, if_exists: true
    end
  end

  describe "generated detail class" do
    it "creates a named constant for the detail class" do
      expect(defined?(TestWidgetDetail)).to eq("constant")
      expect(TestWidgetDetail.superclass).to eq(ApplicationRecord)
    end

    it "sets up the back-reference belongs_to with conventional FK" do
      reflection = TestWidgetDetail.reflect_on_association(:test_widget)
      expect(reflection).to be_present
      expect(reflection.macro).to eq(:belongs_to)
      expect(reflection.foreign_key).to eq("test_widget_id")
    end

    it "evaluates the block on the detail class" do
      reflection = TestWidgetDetail.reflect_on_association(:related_widget)
      expect(reflection).to be_present
      expect(reflection.macro).to eq(:belongs_to)
      expect(reflection.options[:class_name]).to eq("TestWidget")
    end
  end

  describe "detail association" do
    it "auto-builds a detail record for new instances" do
      widget = TestWidget.new(name: "Test")
      expect(widget.detail).to be_present
      expect(widget.detail).to be_a(TestWidgetDetail)
      expect(widget.detail).to be_new_record
    end

    it "does not overwrite an existing detail on persisted records" do
      widget = TestWidget.create!(name: "Persisted")
      detail_id = widget.detail.id

      reloaded = TestWidget.find(widget.id)
      expect(reloaded.detail.id).to eq(detail_id)
    end

    it "destroys the detail when the owner is destroyed" do
      widget = TestWidget.create!(name: "Doomed")
      detail_id = widget.detail.id
      widget.destroy!

      expect(TestWidgetDetail.find_by(id: detail_id)).to be_nil
    end

    it "aliases the concrete association to #detail" do
      widget = TestWidget.create!(name: "Aliased")
      expect(widget.detail).to eq(widget.test_widget_detail)
    end

    it "duplicates the detail when the owner is dup'ed" do
      widget = TestWidget.create!(name: "Original", fancy: true)
      copy = widget.dup

      expect(copy.detail).to be_present
      expect(copy.detail).to be_new_record
      expect(copy.detail.id).to be_nil
      expect(copy.fancy).to be true
    end
  end

  describe "attribute delegation" do
    let(:widget) { TestWidget.create!(name: "Delegated") }

    it "delegates column readers" do
      widget.detail.fancy = true
      expect(widget.fancy).to be true
    end

    it "delegates column writers" do
      widget.fancy = true
      expect(widget.detail.fancy).to be true
    end

    describe "belongs_to association delegation" do
      let(:related) { TestWidget.create!(name: "Related") }

      it "delegates the association reader" do
        widget.detail.related_widget = related
        expect(widget.related_widget).to eq(related)
      end

      it "delegates the association writer" do
        widget.related_widget = related
        expect(widget.detail.related_widget).to eq(related)
      end

      it "delegates the _id reader via column delegation" do
        widget.detail.related_widget_id = related.id
        expect(widget.related_widget_id).to eq(related.id)
      end

      it "delegates the _id writer via column delegation" do
        widget.related_widget_id = related.id
        expect(widget.detail.related_widget_id).to eq(related.id)
      end
    end

    it "does not delegate internal columns to the detail" do
      widget.detail.update_column(:created_at, 1.day.ago)
      expect(widget.created_at).not_to eq(widget.detail.created_at)
    end
  end

  describe "attribute assignment during creation" do
    it "persists detail attributes passed to create" do
      created = TestWidget.create!(name: "Creation Test", fancy: true)
      expect(created.reload.fancy).to be true
    end

    it "persists detail attributes passed to new + save" do
      widget = TestWidget.new(name: "New Test", fancy: true)
      expect(widget.fancy).to be true

      widget.save!
      expect(widget.reload.fancy).to be true
    end

    it "persists belongs_to associations passed to create" do
      related = TestWidget.create!(name: "Parent Widget")
      created = TestWidget.create!(name: "Child Widget", related_widget: related)

      expect(created.reload.related_widget).to eq(related)
    end

    it "defaults detail attributes to their column defaults when not specified" do
      created = TestWidget.create!(name: "Default Test")
      expect(created.reload.fancy).to be false
    end
  end

  describe "error promotion" do
    it "promotes detail validation errors onto the owner" do
      I18n.backend.store_translations(:en,
                                      activerecord: {
                                        attributes: {
                                          test_widget_detail: { related_widget: "Related widget" },
                                          test_widget: { related_widget: "Related widget" }
                                        }
                                      })

      widget = TestWidget.create!(name: "Error Test")
      widget.related_widget_id = 0

      expect(widget).not_to be_valid
      expect(widget.errors[:related_widget]).to be_present
    end

    it "is valid when the detail is valid" do
      widget = TestWidget.create!(name: "Valid Test")
      expect(widget).to be_valid
    end
  end
end
