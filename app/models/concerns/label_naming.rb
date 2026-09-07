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

# Naming rules shared by Project#label_prefix and CustomOption#value.
#
# The fragment is defined once and both anchored forms derived from it. Keeping the fragment
# unanchored is necessary - it is embedded before a hyphen in LABEL_FORMAT - but using it
# unanchored to validate a prefix would accept any string CONTAINING a valid prefix, so
# "TOOLONG" would pass by matching its first six characters. Hence the derived constants:
# no call site has to remember to anchor.
module LabelNaming
  PREFIX_FRAGMENT = /[A-Z][A-Z0-9]{1,5}/
  PREFIX_FORMAT = /\A#{PREFIX_FRAGMENT}\z/
  # The shape a project label is expected to take: a prefix, a hyphen, then a name of one or
  # more words, e.g. "AT-bounce" or "AT-bounce-handling".
  #
  # Case is deliberately not part of the rule. The distinction that carries meaning is the
  # prefix, which is uppercase by its own format; forcing the name to start uppercase too
  # only rejects the spelling people reach for first. Words may be separated by "-" or "_",
  # and that stays unambiguous because prefixed_with? matches "AT-" from the start, so the
  # FIRST hyphen always ends the prefix however many follow it.
  #
  # Admins may set a stricter custom_fields.option_pattern on top of this. They cannot set a
  # looser one: this is applied independently of the pattern, and is the structural floor.
  LABEL_FORMAT = /\A#{PREFIX_FRAGMENT}-[A-Za-z0-9]+(?:[-_][A-Za-z0-9]+)*\z/

  module_function

  # A project label must carry its own project's prefix, e.g. "AT-" for ArchTech.
  def prefixed_with?(value, prefix)
    return false if value.blank? || prefix.blank?

    value.start_with?("#{prefix}-")
  end
end
