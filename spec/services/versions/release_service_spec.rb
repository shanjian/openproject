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

RSpec.describe Versions::ReleaseService do
  let(:user) { create(:admin) }
  let(:type) { create(:type) }
  let(:project) { create(:project, types: [type]) }
  let(:release) { create(:version, project:, name: "Release 1.0", kind: "release") }
  let(:next_release) { create(:version, project:, name: "Release 1.1", kind: "release") }
  # Multi-value version custom field marked as the Release field (the realistic setup).
  let(:release_cf) { create(:multi_version_wp_custom_field, version_kind: "release") }
  let(:closed_status) { create(:closed_status) }
  let(:open_status) { create(:status) }

  let!(:incomplete_wp) { create(:work_package, project:, type:, status: open_status) }
  let!(:done_wp) { create(:work_package, project:, type:, status: closed_status) }

  subject(:service) { described_class.new(user:, version: release) }

  before do
    # Activate the Release custom field for the project and type (as in real usage),
    # then link the work packages to the release through it.
    project.work_package_custom_fields << release_cf
    type.custom_fields << release_cf
    RequestStore.clear!
    link_to_release(incomplete_wp, release)
    link_to_release(done_wp, release)
  end

  # Links the work package to +version+ through the Release custom field, the way the
  # application does (so the value is a proper, available custom field value).
  def link_to_release(work_package, version)
    work_package.custom_field_values = { release_cf.id => [version.id.to_s] }
    work_package.save!
  end

  def linked_releases(work_package)
    CustomValue.where(custom_field: release_cf, customized: work_package).pluck(:value).compact_blank
  end

  describe "#call" do
    context "with strategy 'force'" do
      it "closes the release and leaves incomplete work packages linked" do
        result = service.call(strategy: "force")

        expect(result).to be_success
        expect(release.reload.status).to eq("closed")
        expect(linked_releases(incomplete_wp)).to contain_exactly(release.id.to_s)
      end

      it "records when the release happened" do
        freeze_time do
          service.call(strategy: "force")

          expect(release.reload.released_at).to eq(Time.current)
        end
      end
    end

    context "with strategy 'decouple'" do
      it "closes the release and clears the link from incomplete work packages only" do
        result = service.call(strategy: "decouple")

        expect(result).to be_success
        expect(release.reload.status).to eq("closed")
        expect(linked_releases(incomplete_wp)).to be_empty
        # the done work package keeps its link
        expect(linked_releases(done_wp)).to contain_exactly(release.id.to_s)
      end
    end

    context "with strategy 'roll_forward'" do
      it "moves incomplete work packages to the target release and closes the release" do
        result = service.call(strategy: "roll_forward", target_version: next_release)

        expect(result).to be_success
        expect(release.reload.status).to eq("closed")
        expect(linked_releases(incomplete_wp)).to contain_exactly(next_release.id.to_s)
        expect(linked_releases(done_wp)).to contain_exactly(release.id.to_s)
      end

      it "fails without a target" do
        result = service.call(strategy: "roll_forward")

        expect(result).to be_failure
        expect(release.reload.status).to eq("open")
      end

      it "fails when the target is not an open release" do
        sprint = create(:version, project:, kind: "sprint")
        result = service.call(strategy: "roll_forward", target_version: sprint)

        expect(result).to be_failure
      end

      it "fails when the target release belongs to an unrelated project" do
        foreign_release = create(:version, project: create(:project), kind: "release")
        result = service.call(strategy: "roll_forward", target_version: foreign_release)

        expect(result).to be_failure
        expect(release.reload.status).to eq("open")
        expect(linked_releases(incomplete_wp)).to contain_exactly(release.id.to_s)
      end
    end

    describe "journaling", with_settings: { journal_aggregation_time_minutes: 0 } do
      it "records the release change in the affected work package's journal" do
        expect { service.call(strategy: "decouple") }
          .to change { incomplete_wp.reload.journals.count }.by(1)
      end
    end

    context "with an invalid strategy" do
      it "fails and does not close the release" do
        result = service.call(strategy: "bogus")

        expect(result).to be_failure
        expect(release.reload.status).to eq("open")
        expect(release.released_at).to be_nil
      end
    end

    context "when the version is not a release" do
      subject(:service) { described_class.new(user:, version: create(:version, project:, kind: "sprint")) }

      it "fails" do
        expect(service.call(strategy: "force")).to be_failure
      end
    end

    context "when the user lacks permission" do
      subject(:service) { described_class.new(user: create(:user), version: release) }

      it "fails and does not close the release" do
        result = service.call(strategy: "force")

        expect(result).to be_failure
        expect(release.reload.status).to eq("open")
      end
    end
  end
end
