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
require_module_spec_helper

RSpec.describe GitlabUserToken do
  shared_let(:user) { create(:user) }

  it "stores and reads back the token" do
    record = described_class.create!(user:, token: "glpat-abc")

    expect(record.reload.token).to eq("glpat-abc")
  end

  it "requires a token" do
    expect(described_class.new(user:, token: "")).not_to be_valid
  end

  it "allows only one token per user" do
    described_class.create!(user:, token: "one")
    duplicate = described_class.new(user:, token: "two")

    expect(duplicate).not_to be_valid
  end

  it "is removed when its user is deleted (FK cascade)" do
    deletable = create(:user)
    described_class.create!(user: deletable, token: "gone")

    expect { deletable.destroy }.to change(described_class, :count).by(-1)
  end

  describe "encryption at rest" do
    # The token must be encrypted regardless of the optional database_cipher_key
    # setting, because it uses secret_key_base (not Redmine::Ciphering).
    it "does not persist the raw token even without a database cipher key" do
      allow(OpenProject::Configuration).to receive(:[]).and_call_original
      allow(OpenProject::Configuration).to receive(:[]).with("database_cipher_key").and_return(nil)

      record = described_class.create!(user:, token: "glpat-secret")

      expect(record.read_attribute(:token)).not_to include("glpat-secret")
      expect(record.reload.token).to eq("glpat-secret")
    end

    it "returns nil rather than raising if the stored ciphertext is unreadable" do
      record = described_class.create!(user:, token: "glpat-secret")
      record.update_column(:token, "not-a-valid-ciphertext")

      expect(record.reload.token).to be_nil
    end
  end
end
