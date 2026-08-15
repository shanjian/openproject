# frozen_string_literal: true

require "spec_helper"
require "contracts/shared/model_contract_shared_context"

RSpec.describe RecurringMeetings::EndSeriesContract do
  include_context "ModelContract shared context"

  shared_let(:project) { create(:project) }
  shared_let(:user) { create(:user, member_with_permissions: { project => [:edit_meetings] }) }
  let(:meeting) do
    create(:recurring_meeting,
           project:,
           time_zone: "Asia/Tokyo",
           start_time: Time.zone.today - 1.month,
           end_date: end_date)
  end
  let(:end_date) { Time.zone.today }
  let(:contract) { described_class.new(meeting, user) }

  around do |example|
    Time.use_zone("UTC", &example)
  end

  it "accepts an end date equal to the series time zone's today" do
    allow(meeting.time_zone).to receive(:today).and_return(end_date)

    expect(contract).to be_valid
  end

  context "when the end date is after the series time zone's today" do
    let(:end_date) { Time.zone.today + 1.day }

    it "is invalid" do
      allow(meeting.time_zone).to receive(:today).and_return(Time.zone.today)

      expect(contract).not_to be_valid
      expect(contract.errors[:end_date]).to be_present
    end
  end

  context "with the default end date" do
    let(:end_date) { Time.zone.yesterday }

    it "remains valid for the existing end-series action" do
      expect(contract).to be_valid
    end
  end
end
