# frozen_string_literal: true

#-- copyright
# OpenProject is an open source project management software.
# Copyright (C) 2023 Ben Tey
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License version 3.
#
# OpenProject is a fork of ChiliProject, which is a fork of Redmine. The copyright follows:
# Copyright (C) 2006-2013 Jean-Philippe Lang
# Copyright (C) 2010-2013 the ChiliProject Team
# Copyright (C) the OpenProject GmbH
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
# See docs/COPYRIGHT.rdoc for more details.
#++

module OpenProject::GitlabIntegration
  module NotificationHandler
    module Helper
      ##
      # Parses the given source string and returns a list of work_package ids
      # which it finds and should be considered public or private.
      # WorkPackages are identified by their URL.
      # Params:
      #  source: string
      # Returns:
      #   Array<int>
      def extract_work_package_ids(text, kind = "")
        # matches the following things (given that `Setting.host_name` equals 'www.openproject.org')
        #  - http://www.openproject.org/wp/1234
        #  - https://www.openproject.org/wp/1234
        #  - http://www.openproject.org/work_packages/1234
        #  - https://www.openproject.org/subdirectory/work_packages/1234
        # Or with the following prefix: OP# PP#
        # e.g.,: This is a reference to OP#1234
        # For private comments you can use the prefix: PP#
        host_name = Regexp.escape(Setting.host_name)
        wp_regex = if kind == "private"
                     /PP#(\d+)/
                   elsif kind != "note"
                     /OP#(\d+)|PP#(\d+)|http(?:s?):\/\/#{host_name}\/(?:\S+?\/)*(?:work_packages|wp)\/([0-9]+)/
                   else
                     /OP#(\d+)|http(?:s?):\/\/#{host_name}\/(?:\S+?\/)*(?:work_packages|wp)\/([0-9]+)/
                   end
        String(text)
          .scan(wp_regex)
          .map { |first, second| (first || second).to_i }
          .select(&:positive?)
          .uniq
      end

      ##
      # Given a list of work package ids this methods returns all work packages that match those ids
      # and are visible by the given user.
      # Params:
      #  - Array<int>: An list of WorkPackage ids
      #  - User: The user who may (or may not) see those WorkPackages
      # Returns:
      #  - Array<WorkPackage>
      def find_visible_work_packages(ids, user)
        WorkPackage
          .includes(:project)
          .where(id: ids)
          .select { |wp| user.allowed_in_work_package?(:add_work_package_comments, wp) }
      end

      # Returns a list of `WorkPackage`s that were referenced in the `text` and are visible to the given `user`.
      def find_mentioned_work_packages(text, user, kind = "")
        find_visible_work_packages(extract_work_package_ids(text, kind), user)
      end

      # Returns a list of `WorkPackage`s that were excluded in the `text`.
      def find_excluded_work_packages(text, user)
        find_visible_work_packages(extract_work_package_ids(text, "private"), user)
      end

      ##
      # Returns the `WorkPackage`s a Git branch references and that are visible to
      # the given `user`. A branch references a work package when its name either
      #  - follows OpenProject's `{type}/{id}-{slug}` branch-naming convention
      #    (what the "create branch" action produces), or
      #  - contains an explicit `OP#<id>` / work package URL.
      def find_branch_work_packages(branch_name, user)
        explicit = find_visible_work_packages(extract_work_package_ids(branch_name), user)
        (explicit + convention_work_packages(branch_name, user)).uniq
      end

      # Work packages referenced through OpenProject's branch-naming convention.
      # A candidate id is taken from the `<type>/<id>-…` shape and only kept when
      # the branch actually starts with that work package's canonical prefix, so a
      # date-like branch such as `release/2024-01-15` does not spuriously match
      # work package #2024 (unless its type also sanitizes to "release").
      def convention_work_packages(branch_name, user)
        candidate_ids = branch_name.to_s.scan(%r{(?:\A|/)(\d+)-}).flatten.map(&:to_i).uniq
        return [] if candidate_ids.empty?

        find_visible_work_packages(candidate_ids, user)
          .select { |work_package| branch_follows_convention?(branch_name, work_package) }
      end

      # Mirrors GitlabIntegration::CreateBranchService#branch_name so detection and
      # creation agree on the convention. Branches created via the git-actions panel
      # may carry a trailing `-MMDD-HHmm` timestamp suffix (for follow-up branches);
      # since this is a prefix (start_with?) check, that suffix doesn't affect it.
      def branch_follows_convention?(branch_name, work_package)
        branch_name = branch_name.to_s.downcase

        branch_convention_prefixes(branch_name, work_package).any? do |prefix|
          branch_name.start_with?(prefix)
        end
      end

      # The frontend reserves space for its timestamp suffix before truncating
      # the type. Accept both the default (no suffix) and timestamp budgets so
      # convention matching remains consistent for generated branches whose
      # subject happens to end in a timestamp-shaped string.
      def branch_convention_prefixes(branch_name, work_package)
        suffix_lengths = branch_name.match?(/-\d{4}-\d{4}\z/) ? [0, 10] : [0]

        suffix_lengths.map do |suffix_length|
          branch_convention_prefix(work_package, suffix_length)
        end.uniq
      end

      def branch_convention_prefix(work_package, suffix_length)
        budget = ::GitlabIntegration::CreateBranchService::MAX_LENGTH -
                 "#{work_package.id}-".length - suffix_length
        type_room = [budget - 1, 0].max
        type = truncated_branch_type(work_package, type_room)
        type_prefix = type.present? ? "#{type}/" : ""

        "#{type_prefix}#{work_package.id}-".downcase
      end

      def truncated_branch_type(work_package, type_room)
        sanitize_branch_segment(work_package.type&.name).downcase[0, type_room].to_s
          .sub(/-+\z/, "")
      end

      def sanitize_branch_segment(str)
        str.to_s
           .gsub("&", "and ")
           .gsub(/\W+/, "-")
           .delete_prefix("-")
           .delete_suffix("-")
           .strip
      end

      ##
      # Adds comments to the given WorkPackages.
      #
      # +event+ names the GitLab event family this comment reports (see
      # Journal::CausedByGitlabEvent::EVENTS). It does double duty: projects can
      # switch off individual families on their GitLab settings page, and the
      # journal is tagged with it so the activity tab can tell integration
      # chatter apart from what people wrote.
      #
      # When +deduplicate+ is set, a work package is skipped if it already carries
      # a journal with the exact same note. This keeps the activity clean when the
      # same GitLab event is delivered twice -- e.g. a push or merge request that
      # arrives via both a per-repository webhook and an instance-wide system hook.
      # The generated notes embed stable identifiers (commit SHA, merge request
      # number and URL), so an identical note always denotes the same event; only
      # push and merge-request events are duplicated this way (system hooks do not
      # send issue or note events), which is why callers opt in explicitly.
      def comment_on_referenced_work_packages(work_packages, user, notes, event:, deduplicate: false)
        return if notes.nil?

        cause = Journal::CausedByGitlabEvent.new(event:)

        work_packages.each do |work_package|
          next unless commenting_enabled?(work_package, event)
          next if deduplicate && already_commented?(work_package, notes)

          ::WorkPackages::UpdateService
            .new(user:, model: work_package)
            .call(journal_notes: notes, journal_cause: cause, send_notifications: false)
        end
      end

      # The work package's own project decides, since that is the activity the
      # comment would show up in.
      def commenting_enabled?(work_package, event)
        work_package.project&.gitlab_comments_on?(event)
      end

      def already_commented?(work_package, notes)
        work_package.journals.exists?(notes:)
      end

      # How much of a mirrored GitLab discussion note is reproduced in the
      # activity. Copying whole bodies used to replay entire review threads --
      # including bot output -- inside the work package, burying the comments
      # people actually wrote. The link in the note leads to the full text.
      NOTE_EXCERPT_LIMIT = 200

      def note_excerpt(note)
        String(note).squish.truncate(NOTE_EXCERPT_LIMIT, separator: " ")
      end

      ##
      # Adds comments to the given WorkPackages.
      def status_on_referenced_work_packages(work_packages, user, status)
        work_packages.each do |work_package|
          ::WorkPackages::UpdateService
            .new(user:, model: work_package)
            .call(status_id: status)
        end
      end

      ##
      # A wapper around a ruby Hash to access webhook payloads.
      # All methods called on it are converted to `.fetch` hash-access, raising an error if the string-key does not exist.
      # If the method ends with a question mark, e.g. "comment?" not error is raised if the key does not exist.
      # If the fetched value is again a hash, the value is wrapped into a new payload object.
      class Payload
        def initialize(payload)
          @payload = payload
        end

        def to_h
          @payload.dup
        end

        def method_missing(name, *args, &block)
          super unless args.empty? && block.nil?

          value = if name.end_with?("?")
                    @payload.fetch(name.to_s[..-2], nil)
                  else
                    @payload.fetch(name.to_s)
                  end

          return Payload.new(value) if value.is_a?(Hash)

          value
        end

        def respond_to_missing?(_method_name, _include_private = false)
          true
        end
      end

      def wrap_payload(payload)
        Payload.new(payload)
      end
    end
  end
end
