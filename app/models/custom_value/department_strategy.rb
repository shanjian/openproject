# frozen_string_literal: true

class CustomValue::DepartmentStrategy < CustomValue::ARObjectStrategy
  def formatted_value
    department = cached_ar_object

    if department
      department.ancestry_path
    else
      "#{value} #{I18n.t(:label_not_found)}"
    end
  end

  private

  def ar_class
    Group
  end

  def ar_object(value)
    Group.organizational_units.find_by(id: value)
  end
end
