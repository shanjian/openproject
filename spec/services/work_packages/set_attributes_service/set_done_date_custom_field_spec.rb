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

RSpec.describe WorkPackages::SetAttributesService,
               "stamping a completion date custom field when status changes to Done",
               type: :model do
  shared_let(:done_date_cf) { create(:work_package_custom_field, field_format: "date", is_for_all: true) }
  shared_let(:type) { create(:type, custom_fields: [done_date_cf]) }
  shared_let(:project) { create(:project, types: [type]) }
  shared_let(:open_status) { create(:status, name: "In progress") }
  shared_let(:done_status) { create(:closed_status, name: "Done") }
  shared_let(:closed_status) { create(:closed_status, name: "Closed") }

  let(:user) { build_stubbed(:user) }
  let(:today) { Time.zone.today }

  let(:work_package) { create(:work_package, project:, type:, status: open_status) }

  # Mock the contract so the service applies attributes without requiring a
  # workflow to be set up for the status transitions under test.
  let(:contract_valid) { true }
  let(:mock_contract_instance) do
    instance_double(WorkPackages::UpdateContract,
                    assignable_statuses: [open_status, done_status, closed_status],
                    errors: instance_double(ActiveModel::Errors).as_null_object,
                    validate: contract_valid)
  end
  let(:mock_contract) { class_double(WorkPackages::UpdateContract, new: mock_contract_instance) }
  let(:instance) { described_class.new(user:, model: work_package, contract_class: mock_contract) }

  # value of the configured-custom-field setting under test
  let(:setting_value) { done_date_cf.id.to_s }

  before do
    allow(Setting).to receive(:work_package_done_date_custom_field_id).and_return(setting_value)
  end

  # Applies the given attributes and returns the (in-memory) value of the
  # completion-date custom field afterwards.
  def done_date_after(attributes)
    instance.call(attributes)
    work_package.custom_value_for(done_date_cf)&.typed_value
  end

  context "when the setting points at the date custom field" do
    it "stamps the field with the current date when moving to Done" do
      expect(done_date_after(status: done_status)).to eq(today)
    end

    it "does not stamp the field when moving to another closed status (e.g. Closed)" do
      expect(done_date_after(status: closed_status)).to be_blank
    end

    it "does not stamp the field when the status does not change" do
      expect(done_date_after(subject: "still in progress")).to be_blank
    end
  end

  context "when the setting is blank (disabled)" do
    let(:setting_value) { "" }

    it "does not stamp the field when moving to Done" do
      expect(done_date_after(status: done_status)).to be_blank
    end
  end

  context "when the setting points at a custom field that no longer exists" do
    let(:setting_value) { "0" }

    it "does nothing and does not raise when moving to Done" do
      expect { done_date_after(status: done_status) }.not_to raise_error
      expect(work_package.custom_value_for(done_date_cf)&.typed_value).to be_blank
    end
  end
end
