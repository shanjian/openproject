# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Marking notifications as read by opening the work package", :js do
  let(:center) { Pages::Notifications::Center.new }
  let(:split_screen) { Pages::PrimerizedSplitWorkPackage.new work_package }
  let(:full_view) { Pages::FullWorkPackage.new work_package, project }

  shared_let(:project) { create(:project) }
  shared_let(:work_package) { create(:work_package, project:) }
  shared_let(:second_work_package) { create(:work_package, project:) }

  shared_let(:recipient) do
    create(:user,
           member_with_permissions: { project => %i[view_work_packages] })
  end

  shared_let(:notification) do
    create(:notification,
           recipient:,
           resource: work_package,
           journal: work_package.journals.last)
  end

  shared_let(:second_notification) do
    create(:notification,
           recipient:,
           resource: second_work_package,
           journal: second_work_package.journals.last)
  end

  current_user { recipient }

  describe "opening the split view from the notification center" do
    before do
      visit home_path
      wait_for_reload
      center.open
      center.show_all
    end

    it "marks that work package's notifications as read and leaves the others alone" do
      center.expect_bell_count 2

      center.click_item notification
      split_screen.expect_open

      center.expect_bell_count 1

      # The row stays in the list on the "All" facet and re-renders in its read state,
      # rather than disappearing.
      center.expect_read_item notification
      center.expect_item_not_read second_notification

      # Opening a notification must not skip the user on to the next one.
      split_screen.expect_open

      expect(notification.reload.read_ian).to be true
      expect(second_notification.reload.read_ian).to be false
    end
  end

  describe "opening the work package full view" do
    it "marks that work package's notifications as read" do
      full_view.visit!
      full_view.ensure_page_loaded

      retry_block(args: { tries: 8 }) do
        notification.reload
        raise "Expected the notification to be marked read on open" unless notification.read_ian
      end

      expect(second_notification.reload.read_ian).to be false
    end
  end

  describe "when the user has no unread notifications for the work package" do
    before do
      notification.update!(read_ian: true)
      second_notification.update!(read_ian: true)
    end

    it "does not fail when opening the full view" do
      full_view.visit!
      full_view.ensure_page_loaded

      full_view.expect_no_toaster type: :error
      expect(page).to have_no_test_selector("mark-notification-read-button")
    end
  end
end
