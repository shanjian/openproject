# frozen_string_literal: true

class MeetingNotificationService
  attr_reader :meeting, :content_type

  def initialize(meeting)
    @meeting = meeting
  end

  # Sends +action+ mails to the meeting's participants.
  #
  # actor: the user the mail is rendered as acting user. Background jobs must pass
  #   the captured editor explicitly, since User.current is not the editing user there.
  # force: sends even when the organizer muted the meeting. Used by restore, whose
  #   re-invitation must reach participants the same way the preceding cancellation did.
  def call(action, actor: User.current, force: false, **)
    if force || bypasses_mute?(action) || meeting.notify?
      recipients_with_errors = send_notifications!(action, actor, **)
      ServiceResult.new(success: recipients_with_errors.empty?, errors: recipients_with_errors)
    else
      ServiceResult.failure(errors: meeting.participants.includes(:user))
    end
  end

  private

  # Mails removing the meeting from participants' calendars must not be silenced
  # by the organizer-level mute toggle.
  def bypasses_mute?(action)
    action == :cancelled
  end

  def send_notifications!(action, actor, **)
    recipients_with_errors = []
    meeting.participants.includes(:user).find_each do |recipient|
      next if skip_recipient?(action, recipient)

      MeetingMailer.send(action, meeting, recipient.user, actor, **).deliver_later
    rescue StandardError => e
      Rails.logger.error do
        "Failed to deliver #{action} notification to #{recipient.mail}: #{e.message}"
      end
      recipients_with_errors << recipient
    end

    recipients_with_errors
  end

  def skip_recipient?(action, recipient)
    %i[updated closed reopened].include?(action) && opted_in_user_ids.exclude?(recipient.user_id)
  end

  # The meeting_updated preference is global-only by design: project-scoped rows
  # hardcode email settings to false, so consulting them would silently mask a
  # default-on setting. Query global rows only.
  def opted_in_user_ids
    @opted_in_user_ids ||= NotificationSetting
      .where(project_id: nil, meeting_updated: true, user_id: meeting.participants.select(:user_id))
      .pluck(:user_id)
  end
end
