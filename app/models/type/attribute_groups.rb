# frozen_string_literal: true

#-- copyright
# OpenProject is an open source project management software.
# Copyright (C) the OpenProject GmbH
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License version 3.
#
# OpenProject is a fork of ChiliProject, which is a fork of Redmine. The copyright follows:
# Copyright (C) 2006-2013 Jean-Philippe Lang
# Copyright (C) 2010-2013 the ChiliProject Team
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
#
# See COPYRIGHT and LICENSE files for more details.
#++

module Type::AttributeGroups
  extend ActiveSupport::Concern
  REPORTER_TYPE_NAMES = [
    "task",
    "bug",
    "user story",
    "epic",
    "feature",
    "summary task",
    "milestone"
  ].freeze

  included do
    before_save :write_attribute_groups_objects
    after_save :unset_attribute_groups_objects
    after_destroy :remove_attribute_groups_queries

    serialize :attribute_groups, type: Array
    attr_accessor :attribute_groups_objects

    # Mapping from AR attribute name to a default group
    # May be extended by plugins
    mattr_accessor :default_group_map do
      {
        assignee: :people,
        responsible: :people,
        estimated_time: :estimates_and_progress,
        remaining_time: :estimates_and_progress,
        percentage_done: :estimates_and_progress,
        spent_time: :estimates_and_progress,
        priority: :details
      }
    end

    # All known default
    mattr_accessor :default_groups do
      {
        people: :label_people,
        estimates_and_progress: :label_estimates_and_progress,
        details: :label_details,
        other: :label_other,
        children: :"activerecord.attributes.work_package.children"
      }
    end
  end

  class_methods do
    ##
    # Add a new default group name
    def add_default_group(name, label_key)
      default_groups[name.to_sym] = label_key
    end

    ##
    # Add a mapping from attribute key to an existing default group
    def add_default_mapping(group, *keys)
      unless default_groups.include? group
        raise ArgumentError, "Can't add mapping for '#{keys.inspect}'. Unknown default group '#{group}'."
      end

      keys.each do |key|
        default_group_map[key.to_sym] = group
      end
    end
  end

  ##
  # Read the serialized attribute groups, if customized.
  # Otherwise, return +default_attribute_groups+
  def attribute_groups
    self.attribute_groups_objects ||= begin
      groups = custom_attribute_groups || default_attribute_groups
      groups = add_reporter_to_people(groups) if add_reporter_to_people?

      to_attribute_group_class(groups)
    end

    attribute_groups_objects
  end

  ##
  # Resets the default attribute groups
  def reset_attribute_groups
    # Remove all active custom fields
    self.custom_field_ids = []

    self.attribute_groups_objects = to_attribute_group_class(default_attribute_groups)
  end

  ##
  # Update the attribute groups object.
  def attribute_groups=(groups)
    attribute_groups_will_change!
    self.attribute_groups_objects = to_attribute_group_class(groups)
  end

  ##
  # Returns the default +attribute_groups+ put together by
  # the default group map.
  def default_attribute_groups
    values = work_package_attributes_by_default_group_key
    values.reject! { |k, _| k == :estimates_and_progress } if is_milestone?

    groups = default_groups.keys.each_with_object([]) do |groupkey, array|
      members = values[groupkey]
      array << [groupkey, members] if members.present?
    end

    return groups unless add_reporter_to_people?

    add_reporter_to_people(groups)
  end

  def reload(*args)
    unset_attribute_groups_objects
    super
  end

  def reporter_type?
    REPORTER_TYPE_NAMES.include?(name.to_s.strip.downcase)
  end

  def unset_attribute_groups_objects
    self.attribute_groups_objects = nil
  end

  private

  def write_attribute_groups_objects
    return if attribute_groups_objects.nil?

    groups = if attribute_groups_objects == to_attribute_group_class(default_attribute_groups)
               nil
             else
               to_attribute_group_array(attribute_groups_objects)
             end

    self[:attribute_groups] = groups

    cleanup_query_groups_queries
  end

  def custom_attribute_groups
    self[:attribute_groups].presence
  end

  def default_group_key(key)
    if CustomField.custom_field_attribute?(key)
      :other
    else
      default_group_map.fetch(key.to_sym, :details)
    end
  end

  ##
  # Get the default attribute groups for this type.
  # If it has activated custom fields through +custom_field_ids=+,
  # it will put them into the other group.
  def work_package_attributes_by_default_group_key
    active_cfs = active_custom_field_attributes

    work_package_attributes
      .keys
      .select { |key| default_attribute?(active_cfs, key) }
      .sort_by { |key| default_group_map.keys.index(key.to_sym) || default_group_map.keys.size }
      .group_by { |key| default_group_key(key.to_sym) }
  end

  ##
  # Custom fields should not get included into the default form configuration.
  # This method might get patched by modules.
  def default_attribute?(active_cfs, key)
    !(CustomField.custom_field_attribute?(key) && !active_cfs.include?(key))
  end

  # Reporter types surface the (otherwise internal) author attribute as
  # "Reporter" in the People group, in addition to the regular assignee and
  # responsible (Accountable) attributes.
  def add_reporter_to_people(groups)
    normalized_groups = groups.map do |group_key, members|
      normalized_members = Array(members).map(&:to_s)

      normalized_members.delete("author") unless people_group?(group_key)

      [group_key, normalized_members]
    end

    people_group = normalized_groups.find { |group_key, _| people_group?(group_key) }

    if people_group
      people_members = people_group.last
      unless people_members.include?("author")
        assignee_index = people_members.index("assignee")
        insertion_index = assignee_index ? assignee_index + 1 : people_members.length
        people_members.insert(insertion_index, "author")
      end
    else
      normalized_groups << [:people, ["author"]]
    end

    normalized_groups.reject { |_group_key, members| members.blank? }
  end

  def add_reporter_to_people?
    reporter_type?
  end

  def people_group?(group_key)
    group_key.to_s.casecmp("people").zero?
  end

  def to_attribute_group_class(groups)
    groups.map do |group|
      attributes = group[1]
      first_attribute = attributes[0]
      key = group[0]

      if first_attribute.is_a?(Query)
        new_query_group(key, first_attribute)
      elsif first_attribute.is_a?(Symbol) && Type::QueryGroup.query_attribute?(first_attribute)
        query = Query.find_by(id: Type::QueryGroup.query_attribute_id(first_attribute))
        new_query_group(key, query)
      else
        new_attribute_group(key, attributes)
      end
    end
  end

  def to_attribute_group_array(groups)
    groups.map do |group|
      attributes = if group.is_a?(Type::QueryGroup)
                     query = group.query

                     query.save

                     [group.query_attribute_name]
                   else
                     group.attributes
                   end
      [group.key, attributes]
    end
  end

  def new_attribute_group(key, attributes)
    Type::AttributeGroup.new(self, key, attributes)
  end

  def new_query_group(key, query)
    Type::QueryGroup.new(self, key, query)
  end

  def cleanup_query_groups_queries
    return unless attribute_groups_changed?

    new_groups = self[:attribute_groups]
    old_groups = attribute_groups_was

    ids = (old_groups.map(&:last).flatten - new_groups.map(&:last).flatten)
          .filter_map { |k| ::Type::QueryGroup.query_attribute_id(k) }

    Query.where(id: ids).destroy_all
  end

  def remove_attribute_groups_queries
    attribute_groups
      .select { |g| g.is_a?(Type::QueryGroup) }
      .map(&:query)
      .each(&:destroy)
  end
end
