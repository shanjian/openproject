# frozen_string_literal: true

require "spec_helper"

RSpec.describe OkrBoard::Availability do
  shared_let(:project) { create(:project) }
  shared_let(:type) { create(:type) }

  before do
    project.types << type
  end

  subject(:availability) { described_class.new(project) }

  context "with no department-format custom field" do
    it "has no qualifying custom field and is not available" do
      expect(availability.qualifying_custom_field).to be_nil
      expect(availability.available?).to be false
    end
  end

  context "with one department-format custom field enabled on an active type" do
    let!(:custom_field) do
      create(:department_wp_custom_field, types: [type], projects: [project])
    end

    context "and no versions" do
      it "has a qualifying custom field but is not available" do
        expect(availability.qualifying_custom_field).to eq(custom_field)
        expect(availability.available?).to be false
      end
    end

    context "and at least one version" do
      before { create(:version, project:) }

      it "is available" do
        expect(availability.qualifying_custom_field).to eq(custom_field)
        expect(availability.available?).to be true
      end
    end
  end

  context "with a department-format custom field associated with the project but not activated on any active type" do
    let!(:custom_field) do
      create(:department_wp_custom_field, types: [], projects: [project])
    end

    it "does not count it as qualifying" do
      expect(availability.qualifying_custom_field).to be_nil
      expect(availability.available?).to be false
    end
  end

  context "with a department-format custom field that is project-associated and type-activated " \
          "but not usable as a filter" do
    let!(:custom_field) do
      create(:department_wp_custom_field, types: [type], projects: [project], is_filter: false)
    end

    before { create(:version, project:) }

    it "does not count it as qualifying" do
      expect(availability.qualifying_custom_field).to be_nil
      expect(availability.available?).to be false
    end
  end

  context "with two department-format custom fields both enabled on an active type" do
    before do
      create(:department_wp_custom_field, types: [type], projects: [project])
      create(:department_wp_custom_field, types: [type], projects: [project])
      create(:version, project:)
    end

    it "treats it as not qualifying, not as picking the first one" do
      expect(availability.qualifying_custom_field).to be_nil
      expect(availability.available?).to be false
    end
  end
end
