# frozen_string_literal: true

module OkrBoard
  class Availability
    def initialize(project)
      @project = project
    end

    def qualifying_custom_field
      candidates = @project
        .all_work_package_custom_fields
        .where(field_format: "department")
        .merge(WorkPackageCustomField.joins(:types).where(types: { id: @project.types }))
        .merge(WorkPackageCustomField.filter)
        .distinct

      candidates.one? ? candidates.first : nil
    end

    def available?
      qualifying_custom_field.present? && @project.shared_versions.exists?
    end
  end
end
