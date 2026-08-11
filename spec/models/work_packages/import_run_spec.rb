require "spec_helper"

RSpec.describe WorkPackages::ImportRun do
  it "defaults to queued status with no created work packages" do
    run = described_class.new(project: build_stubbed(:project),
                              user: build_stubbed(:user),
                              source: "# Task: Do the thing")

    expect(run.status).to eq("queued")
    expect(run.created_work_package_ids).to eq([])
  end

  it "requires source" do
    run = described_class.new(project: build_stubbed(:project), user: build_stubbed(:user))

    expect(run).not_to be_valid
    expect(run.errors[:source]).to be_present
  end

  it "exposes status as a queryable enum" do
    run = described_class.new(status: "succeeded")

    expect(run).to be_succeeded
  end
end
