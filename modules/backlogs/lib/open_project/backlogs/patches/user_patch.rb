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

module OpenProject::Backlogs::Patches::UserPatch
  def self.included(base)
    base.class_eval do
      include InstanceMethods
    end
  end

  module InstanceMethods
    # Per-list-type defaults for the backlogs "include closed items" toggle.
    # The inbox and version/owner backlogs hide closed work packages by
    # default (they track actionable/future work); the active sprint shows
    # them so completed work stays visible as a measure of progress.
    BACKLOGS_INCLUDE_CLOSED_DEFAULTS = {
      "inbox" => false,
      "sprint" => true,
      "backlog" => false
    }.freeze

    def backlogs_preference(attr, new_value = nil)
      setting = read_backlogs_preference(attr)

      if setting.nil? and new_value.nil?
        new_value = compute_backlogs_preference(attr)
      end

      if new_value.present?
        setting = write_backlogs_preference(attr, new_value)
      end

      setting
    end

    # Whether the given backlogs column should surface closed work packages.
    # State is stored per column (keyed by "<list_type>:<column_id>", or just
    # "<list_type>" for the inbox) in a single preference hash; a column with
    # no stored value falls back to the per-type default above.
    #
    # NOTE: this deliberately does not go through `backlogs_preference`, whose
    # `.present?`/`.presence` checks cannot distinguish a stored `false` from
    # an unset value.
    def backlogs_include_closed?(list_type, column_id = nil)
      store = backlogs_include_closed_store
      key = backlogs_include_closed_key(list_type, column_id)

      if store.key?(key)
        ActiveModel::Type::Boolean.new.cast(store[key])
      else
        BACKLOGS_INCLUDE_CLOSED_DEFAULTS.fetch(list_type.to_s)
      end
    end

    # Persists the include-closed state for a single column. Returns the
    # stored boolean.
    def set_backlogs_include_closed(list_type, column_id, value)
      casted = ActiveModel::Type::Boolean.new.cast(value)
      store = backlogs_include_closed_store.merge(
        backlogs_include_closed_key(list_type, column_id) => casted
      )
      pref[:backlogs_include_closed] = store
      pref.save! unless new_record?

      casted
    end

    protected

    def backlogs_include_closed_store
      (pref[:backlogs_include_closed] || {}).stringify_keys
    end

    def backlogs_include_closed_key(list_type, column_id)
      column_id.presence ? "#{list_type}:#{column_id}" : list_type.to_s
    end

    def read_backlogs_preference(attr)
      setting = pref[:"backlogs_#{attr}"]

      setting.presence
    end

    def write_backlogs_preference(attr, new_value)
      pref[:"backlogs_#{attr}"] = new_value
      pref.save! unless new_record?

      new_value
    end

    def compute_backlogs_preference(attr)
      case attr
      when :task_color
        ("#%0.6x" % rand(0xFFFFFF)).upcase
      when :versions_default_fold_state
        "open"
      else
        raise "Unsupported attribute '#{attr}'"
      end
    end
  end
end

User.include OpenProject::Backlogs::Patches::UserPatch
