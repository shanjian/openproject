# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Notification center pagination", :js do
  let(:center) { Pages::Notifications::Center.new }

  # Keep this in sync with NOTIFICATIONS_MAX_SIZE in the frontend.
  let(:page_size) { 100 }
  let(:extra) { 20 }

  shared_let(:project) { create(:project) }
  shared_let(:newer_work_package) { create(:work_package, project:) }
  shared_let(:older_work_package) { create(:work_package, project:) }

  shared_let(:recipient) do
    create(:user,
           member_with_permissions: { project => %i[view_work_packages] })
  end

  current_user { recipient }

  before do
    # Notifications are returned newest first, so the older work package's notifications
    # fall outside of the first page.
    create_list(:notification, extra, recipient:, resource: older_work_package,
                                      journal: older_work_package.journals.last)
    create_list(:notification, page_size, recipient:, resource: newer_work_package,
                                          journal: newer_work_package.journals.last)

    visit notifications_center_path
    wait_for_reload
  end

  it "tells the user how many notifications are not displayed and can load them" do
    expect(page).to have_css('[data-test-selector^="op-ian-notification-item-"]', count: 1, wait: 30)

    expect(page).to have_text "Showing the #{page_size} most recent notifications. " \
                              "#{extra} more are not displayed."
    expect(page).to have_test_selector("op-ian-center--load-more")

    find_test_selector("op-ian-center--load-more").click
    wait_for_network_idle

    # The older work package's notifications are loaded now, so it shows up as a second
    # row and neither the warning nor the button remain.
    expect(page).to have_css('[data-test-selector^="op-ian-notification-item-"]', count: 2, wait: 30)
    expect(page).to have_no_test_selector("op-ian-center--load-more")
    expect(page).to have_no_text "more are not displayed"
  end
end
