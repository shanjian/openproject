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

require_relative "push_hook"
require_relative "merge_request_hook"

module OpenProject::GitlabIntegration
  module NotificationHandler
    ##
    # Handles GitLab *system hook* notifications.
    #
    # A system hook is configured once, at the instance level (GitLab admin area),
    # and fires for *every* repository on the instance -- unlike a project or group
    # webhook, which has to be set up per repository. This lets a single hook drive
    # branch and merge-request tracking across all repositories, including ones
    # created in the future.
    #
    # Every system-hook delivery arrives with the same `X-Gitlab-Event: System Hook`
    # header, so they are all routed here regardless of the underlying event. The
    # concrete event is carried in the payload instead: merge request (and other
    # newer) events expose `object_kind`, while the original push/tag events expose
    # only `event_name`.
    #
    # We dispatch the events we care about to the very same handlers that process
    # per-repository webhooks, so behaviour is identical whether tracking is driven
    # by a per-repo webhook or by one instance-wide system hook.
    class SystemHook
      def process(payload_params)
        case event_kind(payload_params)
        when "push"
          PushHook.new.process(normalize_push(payload_params))
        when "merge_request"
          MergeRequestHook.new.process(payload_params)
        end
      end

      private

      # The event discriminator. Merge-request system hooks carry `object_kind`;
      # push system hooks carry only `event_name`. Preferring `object_kind` keeps
      # us aligned with the per-repo webhook payloads where both are present.
      def event_kind(payload_params)
        payload_params["object_kind"].presence || payload_params["event_name"].presence
      end

      # A system-hook push identifies itself with `event_name: "push"` and carries
      # no `object_kind`, whereas PushHook guards on `object_kind == "push"` (and
      # the payload wrapper raises on a missing key). Stamp `object_kind` on so the
      # push payload is indistinguishable from a per-repo push webhook downstream.
      def normalize_push(payload_params)
        payload_params.merge("object_kind" => "push")
      end
    end
  end
end
