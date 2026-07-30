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

      # The defaults draw one line: mirror *events*, not *conversations*.
      #
      # A push, a merge request or an issue changing state is something that
      # happened and has no other timestamp in OpenProject, so recording it in
      # the activity earns its place. A GitLab discussion note is a copy of a
      # conversation that already lives in GitLab, one click away through the
      # merge request the activity links to -- and it is by far the largest
      # source of noise, since every review round and every bot posting is
      # reproduced. Projects that want that copy can switch it back on.
      COMMENT_SETTINGS = {
        gitlab_comment_on_push: true,
        gitlab_comment_on_merge_request: true,
        gitlab_comment_on_note: false,
        gitlab_comment_on_issue: true
      }.freeze

      # Deliberately declared without `default:`. Rails writes a store_attribute
      # default into the store when a record is *initialized*, so it would only
      # ever reach projects created after this shipped -- every project that
      # already existed would read nil, and nil is falsy, which would silently
      # switch every GitLab event off for them. The default is applied on read
      # instead, in #gitlab_comments_on?, so it holds for every project no
      # matter what its settings column happens to contain.
      included do
        COMMENT_SETTINGS.each_key do |setting|
          store_attribute :settings, setting, :boolean
        end
      end

      ##
      # Whether the given GitLab event family (see Journal::CausedByGitlabEvent)
      # may post a comment to this project's work packages. A project that never
      # visited the settings page has nothing stored and falls back to the
      # default; an explicit choice, true or false, always wins.
      def gitlab_comments_on?(event)
        setting = :"gitlab_comment_on_#{event}"
        stored = public_send(setting)

        stored.nil? ? COMMENT_SETTINGS.fetch(setting) : stored
      end
    end
  end
end

Project.include OpenProject::GitlabIntegration::Patches::ProjectPatch
