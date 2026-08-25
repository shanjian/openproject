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

RSpec.describe Notifications::Menu do
  shared_let(:project) { create(:project) }
  shared_let(:other_project) { create(:project) }
  shared_let(:author) { create(:user) }

  shared_let(:recipient) do
    create(:user,
           member_with_permissions: {
             project => %i[view_work_packages],
             other_project => %i[view_work_packages]
           })
  end

  shared_let(:work_package) { create(:work_package, project:, author:) }
  shared_let(:other_work_package) { create(:work_package, project: other_project, author:) }

  let(:params) { {} }
  let(:instance) { described_class.new(params:, current_user: recipient) }

  before { login_as(recipient) }

  def count_for(title)
    instance
      .menu_items
      .flat_map(&:children)
      .detect { |item| item.title == title }
      &.count
  end

  context "with several unread notifications on the same work package" do
    before do
      create_list(:notification, 3, recipient:, resource: work_package, reason: :mentioned)
      create(:notification, recipient:, resource: other_work_package, reason: :assigned)
    end

    it "counts each work package once in the inbox" do
      expect(count_for(I18n.t("notifications.menu.inbox"))).to eq 2
    end

    it "counts each work package once per reason" do
      expect(count_for(I18n.t("notifications.reasons.mentioned"))).to eq 1
      expect(count_for(I18n.t("notifications.reasons.assigned"))).to eq 1
    end

    it "counts each work package once per project" do
      expect(count_for(project.name)).to eq 1
      expect(count_for(other_project.name)).to eq 1
    end
  end

  context "with unread notifications of different reasons on the same work package" do
    before do
      create(:notification, recipient:, resource: work_package, reason: :mentioned)
      create(:notification, recipient:, resource: work_package, reason: :assigned)
    end

    it "counts the work package once in the inbox but once under each reason" do
      expect(count_for(I18n.t("notifications.menu.inbox"))).to eq 1
      expect(count_for(I18n.t("notifications.reasons.mentioned"))).to eq 1
      expect(count_for(I18n.t("notifications.reasons.assigned"))).to eq 1
      expect(count_for(project.name)).to eq 1
    end
  end

  context "with several date alert notifications on the same work package" do
    before do
      create(:notification, recipient:, resource: work_package, reason: :date_alert_start_date)
      create(:notification, recipient:, resource: work_package, reason: :date_alert_due_date)
    end

    it "folds them into a single date alert entry counted once" do
      expect(count_for(I18n.t("notifications.reasons.dateAlert"))).to eq 1
      expect(count_for(I18n.t("notifications.menu.inbox"))).to eq 1
    end
  end

  context "when read notifications exist" do
    before do
      create(:notification, recipient:, resource: work_package, reason: :mentioned, read_ian: true)
      create(:notification, recipient:, resource: other_work_package, reason: :mentioned)
    end

    it "ignores them" do
      expect(count_for(I18n.t("notifications.menu.inbox"))).to eq 1
      expect(count_for(I18n.t("notifications.reasons.mentioned"))).to eq 1
      expect(count_for(project.name)).to be_nil
      expect(count_for(other_project.name)).to eq 1
    end
  end
end
