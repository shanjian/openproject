# frozen_string_literal: true

require "spec_helper"

RSpec.describe OpenProject::CustomFieldFormat do
  it "registers the department format" do
    format = described_class.find_by(name: "department")

    expect(format).to be_present
    expect(format.label).to eq(:label_department)
    expect(format.multi_value_possible?).to be(false)
    expect(format.for_class_name?("WorkPackage")).to be(true)
    expect(format.for_class_name?("Project")).to be(false)
  end

  it "keeps the department format available without an Enterprise token" do
    format = described_class.find_by(name: "department")

    expect(format.available?).to be(true)
  end
end
