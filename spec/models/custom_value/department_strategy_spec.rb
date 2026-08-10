# frozen_string_literal: true

require "spec_helper"

RSpec.describe CustomValue::DepartmentStrategy do
  let(:instance) { described_class.new(custom_value) }
  let(:custom_value) { instance_double(CustomValue, value:, custom_field:, customized:) }
  let(:customized) { instance_double(WorkPackage) }
  let(:custom_field) { build(:custom_field, :department) }
  let(:department) { build_stubbed(:department) }

  before do
    allow(Group).to receive(:organizational_units).and_return(Group.none)
    allow(Group.organizational_units).to receive(:find_by)
  end

  describe "#parse_value/#typed_value" do
    subject { instance }

    context "with a department" do
      let(:value) { department }

      it "returns the department and sets it for later retrieval" do
        expect(subject.parse_value(value)).to eql department.id.to_s

        expect(subject.typed_value).to eql value

        expect(Group.organizational_units).not_to have_received(:find_by)
      end
    end

    context "with an id string" do
      let(:value) { department.id.to_s }

      it "returns the string and has to later find the department" do
        allow(Group.organizational_units)
          .to receive(:find_by)
          .with(id: department.id.to_s)
          .and_return(department)

        expect(subject.parse_value(value)).to eql value

        expect(subject.typed_value).to eql department
      end
    end

    context "when value is blank" do
      let(:value) { "" }

      it "is nil and does not look for the department" do
        expect(subject.parse_value(value)).to be_nil

        expect(subject.typed_value).to be_nil

        expect(Group.organizational_units).not_to have_received(:find_by)
      end
    end
  end

  describe "#formatted_value" do
    subject { instance.formatted_value }

    context "with a department" do
      let(:value) { department }

      it "is the department's ancestry path (without db access)" do
        instance.parse_value(value)

        expect(subject).to eql department.ancestry_path

        expect(Group.organizational_units).not_to have_received(:find_by)
      end
    end

    context "when the referenced department no longer exists" do
      let(:value) { "999999" }

      it "falls back to a not-found message instead of raising" do
        allow(Group.organizational_units).to receive(:find_by).with(id: "999999").and_return(nil)

        expect(subject).to eql "999999 #{I18n.t(:label_not_found)}"
      end
    end
  end

  describe "#validate_type_of_value" do
    subject { instance.validate_type_of_value }

    let(:allowed_ids) { %w(12 13) }

    before do
      allow(custom_field).to receive(:possible_values).with(customized).and_return(allowed_ids)
    end

    context "when value is an id of an included element" do
      let(:value) { "12" }

      it "accepts" do
        expect(subject).to be_nil
      end
    end

    context "when value is an id of a non-included element" do
      let(:value) { "10" }

      it "rejects" do
        expect(subject).to be(:inclusion)
      end
    end
  end
end
