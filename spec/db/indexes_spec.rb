# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Typeahead search indexes" do
  it "has a trigram index on work_packages.subject for the typeahead filter's ILIKE search" do
    expect(
      ActiveRecord::Base.connection.index_exists?(:work_packages, :subject,
                                                    name: "index_work_packages_on_subject_trigram")
    ).to be true
  end

  it "has a trigram index on projects.name for the typeahead filter's ILIKE search" do
    expect(
      ActiveRecord::Base.connection.index_exists?(:projects, :name,
                                                    name: "index_projects_on_name_trigram")
    ).to be true
  end
end
