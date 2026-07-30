# frozen_string_literal: true

module OpenProject::GitlabIntegration
  module Patches
    ##
    # Per-project switches for how much GitLab activity is mirrored into work
    # package activity.
    #
    # They live in the `projects.settings` JSONB column rather than in a table of
    # their own, so adding or retiring a switch needs no migration and projects
    # that never touched the settings page simply fall back to the defaults
    # below. The *work package's* project decides -- that is the activity a
    # comment lands in -- which also means the switches apply to repositories
    # that were never mapped to the project (instance-wide system hooks deliver
    # events for every repository on the GitLab instance).
    module ProjectPatch
      extend ActiveSupport::Concern

      COMMENT_SETTINGS = {
        gitlab_comment_on_push: true,
        gitlab_comment_on_merge_request: true,
        gitlab_comment_on_note: true,
        gitlab_comment_on_issue: true
      }.freeze

      included do
        COMMENT_SETTINGS.each do |setting, default|
          store_attribute :settings, setting, :boolean, default:
        end
      end

      ##
      # Whether the given GitLab event family (see Journal::CausedByGitlabEvent)
      # may post a comment to this project's work packages.
      def gitlab_comments_on?(event)
        public_send(:"gitlab_comment_on_#{event}")
      end
    end
  end
end

Project.include OpenProject::GitlabIntegration::Patches::ProjectPatch
