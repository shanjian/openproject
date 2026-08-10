# Admin-shareable invitation & password-reset links Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let admins generate an invitation link or a password-reset link and copy it directly (e.g. to paste into a chat app), instead of relying solely on email delivery.

**Architecture:** Two new `UsersController` actions reuse the existing token models (`Token::Invitation`, `Token::Recovery`) and the existing token-consumption code in `AccountController` — no new consumption logic. Each action redirects back to the user page with the generated URL delivered via the existing `flash[:op_modal]` mechanism, rendered as a new `Users::ShareableLinkDialogComponent` with a one-click copy button (`Primer::Beta::ClipboardCopy`).

**Tech Stack:** Ruby on Rails, RSpec, ViewComponent (Primer::OpenProject), Stimulus (`auto-show-dialog`, no new controller needed).

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-10-admin-shareable-account-links-design.md` — every task below implements a section of it; re-read it if a task's rationale is unclear.
- No new UI for admin-typed passwords; `UsersController#update`'s existing "set password directly" flow is untouched.
- No new token-consumption code: invitation links are consumed by the existing `AccountController#activate`, reset links by the existing `AccountController#lost_password`.
- Follow existing code style: `frozen_string_literal: true` + copyright header on every new Ruby file (copy verbatim from any file touched in this plan).
- Translation strings go in `config/locales/en.yml` only (source locale); never hardcode UI copy.

---

## Task 1: `Token::Recovery` — split email vs. chat-link validity

**Files:**
- Modify: `app/models/token/recovery.rb`
- Test: `spec/models/token/recovery_spec.rb` (new file)

**Interfaces:**
- Produces: `Token::Recovery::CHANNEL_CHAT_LINK` (String constant `"chat_link"`), `Token::Recovery::EMAIL_VALIDITY` (`3.days`), `Token::Recovery::CHAT_LINK_VALIDITY` (`1.day`). A token created with `data: { channel: Token::Recovery::CHANNEL_CHAT_LINK }` expires after `CHAT_LINK_VALIDITY`; any other token (including no `data`) expires after `EMAIL_VALIDITY`. Task 6 creates chat-link tokens with this marker; the existing `AccountController#lost_password` email path creates tokens without it (unchanged call site).

- [ ] **Step 1: Write the failing test**

Create `spec/models/token/recovery_spec.rb`:

```ruby
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

require "spec_helper"

RSpec.describe Token::Recovery do
  let(:user) { create(:user) }

  describe "validity_time" do
    context "without a channel marker (email / self-service flow)" do
      it "expires after EMAIL_VALIDITY" do
        token = described_class.create!(user_id: user.id)

        expect(token.expires_on).to be_within(1.second).of(described_class::EMAIL_VALIDITY.from_now)
      end
    end

    context "with the chat_link channel marker (admin-generated flow)" do
      it "expires after CHAT_LINK_VALIDITY" do
        token = described_class.create!(user_id: user.id, data: { channel: described_class::CHANNEL_CHAT_LINK })

        expect(token.expires_on).to be_within(1.second).of(described_class::CHAT_LINK_VALIDITY.from_now)
      end
    end

    context "with an unrelated data payload" do
      it "still expires after EMAIL_VALIDITY" do
        token = described_class.create!(user_id: user.id, data: { channel: "something_else" })

        expect(token.expires_on).to be_within(1.second).of(described_class::EMAIL_VALIDITY.from_now)
      end
    end
  end

  it "EMAIL_VALIDITY is longer than CHAT_LINK_VALIDITY" do
    expect(described_class::EMAIL_VALIDITY).to be > described_class::CHAT_LINK_VALIDITY
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/models/token/recovery_spec.rb`
Expected: FAIL — `NameError: uninitialized constant Token::Recovery::EMAIL_VALIDITY` (and the first expectation would fail anyway since current `validity_time` is `1.day` for every token).

- [ ] **Step 3: Write minimal implementation**

Replace the full contents of `app/models/token/recovery.rb` (keep the existing copyright header) with:

```ruby
module Token
  class Recovery < Base
    include ExpirableToken

    CHANNEL_CHAT_LINK = "chat_link"
    EMAIL_VALIDITY = 3.days
    CHAT_LINK_VALIDITY = 1.day

    def self.validity_time
      EMAIL_VALIDITY
    end

    def validity_time
      # `data` is nil for a new record until an explicit `data:` value is assigned
      # (Rails does not run a serialized column's coder over its unset default),
      # so `&.dig` is required here, not just for readability.
      data&.dig("channel") == CHANNEL_CHAT_LINK ? CHAT_LINK_VALIDITY : self.class.validity_time
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/models/token/recovery_spec.rb`
Expected: PASS (4 examples)

- [ ] **Step 5: Commit**

```bash
git add app/models/token/recovery.rb spec/models/token/recovery_spec.rb
git commit -m "$(cat <<'EOF'
Split Token::Recovery validity by delivery channel

Email-delivered recovery tokens now stay valid for 3 days instead of
1, since an inbox may sit unread longer than a chat message would.
Tokens marked with a chat_link channel (added in a later commit for
admin-generated links) keep the original 1-day validity.
EOF
)"
```

---

## Task 2: `AccountController#lost_password` — decouple token consumption from the self-service setting

**Files:**
- Modify: `app/controllers/account_controller.rb:93-145` (the `lost_password` action) and `:301-303` (`allow_lost_password_recovery?`, removed)
- Test: `spec/controllers/account_controller_spec.rb`

**Interfaces:**
- Consumes: nothing new.
- Produces: no new public interface — behavior change only. After this task, `GET/POST /account/lost_password` with a `token` param works whenever `!OpenProject::Configuration.disable_password_login?`, regardless of `Setting.lost_password?`. Without a `token` param, behavior is unchanged (still gated by `Setting.lost_password?`).

- [ ] **Step 1: Write the failing test**

In `spec/controllers/account_controller_spec.rb`, find the existing `describe "POST #lost_password" do` block (currently around line 711) and replace it with:

```ruby
  describe "POST #lost_password" do
    context "when the user has been invited but not yet activated" do
      shared_let(:admin) { create(:admin, status: :invited) }
      shared_let(:token) { create(:recovery_token, user: admin) }

      context "with a valid token" do
        before do
          post :lost_password, params: { token: token.value }
        end

        it "redirects to the login page" do
          expect(response).to redirect_to "/login"
        end
      end
    end

    context "when Setting.lost_password? is false", with_settings: { lost_password: false } do
      let(:user) { create(:user) }
      let(:token) { create(:recovery_token, user:) }

      context "with a valid token (admin-issued link)" do
        before do
          get :lost_password, params: { token: token.value }
        end

        it "still renders the password recovery form" do
          expect(response).to render_template "account/password_recovery"
        end
      end

      context "without a token (self-service request)" do
        before do
          get :lost_password
        end

        it "redirects home instead of showing the request form" do
          expect(response).to redirect_to home_url
        end
      end

      context "submitting the self-service request form" do
        let(:mail_user) { create(:user) }

        before do
          post :lost_password, params: { mail: mail_user.mail }
        end

        it "redirects home instead of creating a token" do
          expect(response).to redirect_to home_url
          expect(Token::Recovery.where(user_id: mail_user.id)).to be_empty
        end
      end
    end

    context "when password login is disabled entirely" do
      let(:user) { create(:user) }
      let(:token) { create(:recovery_token, user:) }

      before do
        allow(OpenProject::Configuration).to receive(:disable_password_login?).and_return(true)
      end

      it "redirects home even with a valid token" do
        get :lost_password, params: { token: token.value }

        expect(response).to redirect_to home_url
      end
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/controllers/account_controller_spec.rb -e "POST #lost_password"`
Expected: FAIL on the three new `"when Setting.lost_password? is false"` examples — the current code redirects home for all of them (including the token-present case), so "still renders the password recovery form" fails.

- [ ] **Step 3: Write minimal implementation**

In `app/controllers/account_controller.rb`, replace:

```ruby
  # Enable user to choose a new password
  def lost_password # rubocop:disable Metrics/AbcSize, Metrics/PerceivedComplexity
    return redirect_to(home_url, status: :see_other) unless allow_lost_password_recovery?

    if params[:token]
      @token = ::Token::Recovery.find_by_plaintext_value(params[:token])
      redirect_to(home_url, status: :see_other) && return unless @token and !@token.expired?

      @user = @token.user
      if request.post?
        call = ::Users::ChangePasswordService.new(current_user: @user, session:).call(params)
        call.apply_flash_message!(flash) if call.errors.empty?

        if call.success?
          @token.destroy
          redirect_to action: "login", status: :see_other
          return
        end
      end

      render template: "account/password_recovery"
    elsif request.post?
      mail = params[:mail]
      user = User.find_by_mail(mail) if mail.present?

      # Ensure the same request is sent regardless of which email is entered
      # to avoid detecability of mails
      flash[:notice] = I18n.t(:notice_account_lost_email_sent)

      unless user
        # user not found in db
        Rails.logger.error "Lost password unknown email input: #{mail}"
        redirect_to action: :lost_password, status: :see_other
        return
      end

      unless user.change_password_allowed?
        # user uses an external authentication
        UserMailer.password_change_not_possible(user).deliver_later
        Rails.logger.warn "Password cannot be changed for user: #{mail}"
        redirect_to action: :lost_password, status: :see_other
        return
      end

      # create a new token for password recovery
      token = Token::Recovery.new(user_id: user.id)
      if token.save
        UserMailer.password_lost(token).deliver_later
        flash[:notice] = I18n.t(:notice_account_lost_email_sent)
        redirect_to action: :lost_password, status: :see_other
        nil
      end
    end
  end
```

with:

```ruby
  # Enable user to choose a new password
  def lost_password # rubocop:disable Metrics/AbcSize, Metrics/PerceivedComplexity
    return redirect_to(home_url, status: :see_other) if OpenProject::Configuration.disable_password_login?

    if params[:token]
      @token = ::Token::Recovery.find_by_plaintext_value(params[:token])
      redirect_to(home_url, status: :see_other) && return unless @token and !@token.expired?

      @user = @token.user
      if request.post?
        call = ::Users::ChangePasswordService.new(current_user: @user, session:).call(params)
        call.apply_flash_message!(flash) if call.errors.empty?

        if call.success?
          @token.destroy
          redirect_to action: "login", status: :see_other
          return
        end
      end

      render template: "account/password_recovery"
    else
      return redirect_to(home_url, status: :see_other) unless Setting.lost_password?

      if request.post?
        mail = params[:mail]
        user = User.find_by_mail(mail) if mail.present?

        # Ensure the same request is sent regardless of which email is entered
        # to avoid detecability of mails
        flash[:notice] = I18n.t(:notice_account_lost_email_sent)

        unless user
          # user not found in db
          Rails.logger.error "Lost password unknown email input: #{mail}"
          redirect_to action: :lost_password, status: :see_other
          return
        end

        unless user.change_password_allowed?
          # user uses an external authentication
          UserMailer.password_change_not_possible(user).deliver_later
          Rails.logger.warn "Password cannot be changed for user: #{mail}"
          redirect_to action: :lost_password, status: :see_other
          return
        end

        # create a new token for password recovery
        token = Token::Recovery.new(user_id: user.id)
        if token.save
          UserMailer.password_lost(token).deliver_later
          flash[:notice] = I18n.t(:notice_account_lost_email_sent)
          redirect_to action: :lost_password, status: :see_other
          nil
        end
      end
    end
  end
```

Then delete the now-unused private method (around line 301):

```ruby
  def allow_lost_password_recovery?
    Setting.lost_password? && !OpenProject::Configuration.disable_password_login?
  end

```

(confirm with `grep -rn "allow_lost_password_recovery" app/` that no other caller remains before deleting).

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/controllers/account_controller_spec.rb -e "POST #lost_password"`
Expected: PASS (5 examples)

Also run the full file to check for regressions:

Run: `bundle exec rspec spec/controllers/account_controller_spec.rb`
Expected: PASS (no regressions)

- [ ] **Step 5: Commit**

```bash
git add app/controllers/account_controller.rb spec/controllers/account_controller_spec.rb
git commit -m "$(cat <<'EOF'
Decouple lost_password token consumption from Setting.lost_password?

Setting.lost_password? is meant to control whether users can request
their own reset unsolicited. It previously gated the entire action,
so a valid token issued through another channel (e.g. an
admin-generated link, added in a later commit) would be rejected on
instances that disabled self-service requests. Consuming a token now
only checks disable_password_login?, which is the setting that
actually means "password auth is off system-wide."
EOF
)"
```

---

## Task 3: `UserInvitation.reinvite_user` — optional notification

**Files:**
- Modify: `app/controllers/concerns/user_invitation.rb:92-101`
- Test: `spec/controllers/concerns/user_invitation_spec.rb`

**Interfaces:**
- Produces: `UserInvitation.reinvite_user(user_id, send_notification: true)`. When `false`, no `Events.user_reinvited` notification is sent (so no email fires), but the token is still created/rotated exactly as before. Task 5's `invitation_link` action calls this with `send_notification: false`; the existing `resend_invitation` action is unchanged (calls with no keyword, defaulting to `true`).

- [ ] **Step 1: Write the failing test**

Find the existing `reinvite_user` spec context in `spec/controllers/concerns/user_invitation_spec.rb` (search `describe ".reinvite_user"` or similar — if none exists, add a new `describe` block) and add:

```ruby
  describe ".reinvite_user" do
    let(:user) { create(:invited_user) }

    it "sends a user_reinvited notification by default" do
      allow(OpenProject::Notifications).to receive(:send)

      described_class.reinvite_user(user.id)

      expect(OpenProject::Notifications).to have_received(:send)
        .with(described_class::Events.user_reinvited, an_instance_of(Token::Invitation))
    end

    it "skips the notification when send_notification: false" do
      allow(OpenProject::Notifications).to receive(:send)

      described_class.reinvite_user(user.id, send_notification: false)

      expect(OpenProject::Notifications).not_to have_received(:send)
    end

    it "still creates a fresh token when send_notification: false" do
      old_token = create(:invitation_token, user:)

      new_token = described_class.reinvite_user(user.id, send_notification: false)

      expect(new_token).to be_persisted
      expect(Token::Invitation.exists?(old_token.id)).to be false
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/controllers/concerns/user_invitation_spec.rb -e ".reinvite_user"`
Expected: FAIL with `ArgumentError: unknown keyword: :send_notification` on the second and third examples.

- [ ] **Step 3: Write minimal implementation**

In `app/controllers/concerns/user_invitation.rb`, replace:

```ruby
  def reinvite_user(user_id)
    User.transaction do
      clear_tokens user_id
      reset_login user_id

      Token::Invitation.create!(user_id:).tap do |token|
        OpenProject::Notifications.send Events.user_reinvited, token
      end
    end
  end
```

with:

```ruby
  def reinvite_user(user_id, send_notification: true)
    User.transaction do
      clear_tokens user_id
      reset_login user_id

      Token::Invitation.create!(user_id:).tap do |token|
        OpenProject::Notifications.send(Events.user_reinvited, token) if send_notification
      end
    end
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/controllers/concerns/user_invitation_spec.rb`
Expected: PASS, including all pre-existing examples in the file (no regressions to the `resend_invitation` controller spec's email-sending behavior, which calls `reinvite_user` with no keyword).

- [ ] **Step 5: Commit**

```bash
git add app/controllers/concerns/user_invitation.rb spec/controllers/concerns/user_invitation_spec.rb
git commit -m "$(cat <<'EOF'
Allow UserInvitation.reinvite_user to skip the notification/email

A later commit adds an admin action that generates a copyable
invitation link without emailing it. reinvite_user's token rotation
is exactly what that action needs; only the notification send (which
triggers the email) needs to become optional.
EOF
)"
```

---

## Task 4: `Users::ShareableLinkDialogComponent`

**Files:**
- Create: `app/components/users/shareable_link_dialog_component.rb`
- Create: `app/components/users/shareable_link_dialog_component.html.erb`
- Create: `lookbook/previews/open_project/users/shareable_link_dialog_component_preview.rb`
- Test: `spec/components/users/shareable_link_dialog_component_spec.rb`

**Interfaces:**
- Produces: `Users::ShareableLinkDialogComponent.new(link:, title:, description:)` — a `Primer::Alpha::Dialog` that auto-opens (via the `auto-show-dialog` Stimulus controller) and shows `description`, the `link` in a `clipboard-copy` custom element (via `OpPrimer::CopyToClipboardComponent`, `scheme: :link`), and a "Close" button. `Users::ShareableLinkDialogComponent::DIALOG_ID` is the dialog's DOM id, for use in feature specs. Tasks 5 and 6 render this via `flash_op_modal component: Users::ShareableLinkDialogComponent, parameters: { link:, title:, description: }`.

- [ ] **Step 1: Write the failing test**

Create `spec/components/users/shareable_link_dialog_component_spec.rb`:

```ruby
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

require "spec_helper"

RSpec.describe Users::ShareableLinkDialogComponent, type: :component do
  let(:link) { "https://example.org/account/activate?token=abc123" }

  before do
    render_inline(described_class.new(link:, title: "Invitation link", description: "Share this with the user."))
  end

  it "renders as an auto-showing dialog" do
    expect(page).to have_css("dialog##{described_class::DIALOG_ID}[data-controller='auto-show-dialog']", visible: :all)
  end

  it "shows the title" do
    expect(page).to have_text("Invitation link")
  end

  it "shows the description" do
    expect(page).to have_text("Share this with the user.")
  end

  it "renders the link in a clipboard-copy element" do
    expect(page).to have_css("clipboard-copy[value='#{link}']", visible: :all)
  end

  it "renders a close button" do
    expect(page).to have_button("Close")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/components/users/shareable_link_dialog_component_spec.rb`
Expected: FAIL with `NameError: uninitialized constant Users::ShareableLinkDialogComponent`

- [ ] **Step 3: Write minimal implementation**

Create `app/components/users/shareable_link_dialog_component.rb`:

```ruby
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

module Users
  # Renders a shareable link (invitation or password-reset) after an admin
  # action, delivered via flash[:op_modal]. See OpModalFlashable.
  class ShareableLinkDialogComponent < ApplicationComponent
    include OpPrimer::ComponentHelpers

    DIALOG_ID = "shareable-link-dialog"

    def initialize(link:, title:, description:)
      super()
      @link = link
      @title = title
      @description = description
    end
  end
end
```

Create `app/components/users/shareable_link_dialog_component.html.erb`:

```erb
<%=
  render(
    Primer::Alpha::Dialog.new(
      id: Users::ShareableLinkDialogComponent::DIALOG_ID,
      title: @title,
      data: { controller: "auto-show-dialog" }
    )
  ) do |dialog|
    dialog.with_header(show_divider: false)

    dialog.with_body do
      flex_layout do |flex|
        flex.with_row do
          render(Primer::Beta::Text.new(color: :subtle, tag: :p)) { @description }
        end
        flex.with_row(mt: 2) do
          render(OpPrimer::CopyToClipboardComponent.new(@link, scheme: :link))
        end
      end
    end

    dialog.with_footer(show_divider: false) do
      render(
        Primer::Beta::Button.new(data: { "close-dialog-id": Users::ShareableLinkDialogComponent::DIALOG_ID })
      ) { t(:button_close) }
    end
  end
%>
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/components/users/shareable_link_dialog_component_spec.rb`
Expected: PASS (5 examples)

- [ ] **Step 5: Add the Lookbook preview**

Create `lookbook/previews/open_project/users/shareable_link_dialog_component_preview.rb`:

```ruby
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

module OpenProject::Users
  # @logical_path OpenProject/Users
  class ShareableLinkDialogComponentPreview < Lookbook::Preview
    # @param link text
    # @param title text
    # @param description text
    def default(link: "https://example.org/account/activate?token=abc123",
                title: "Invitation link",
                description: "Share this link with the user so they can activate their account.")
      render(Users::ShareableLinkDialogComponent.new(link:, title:, description:))
    end
  end
end
```

- [ ] **Step 6: Commit**

```bash
git add app/components/users/shareable_link_dialog_component.rb \
        app/components/users/shareable_link_dialog_component.html.erb \
        lookbook/previews/open_project/users/shareable_link_dialog_component_preview.rb \
        spec/components/users/shareable_link_dialog_component_spec.rb
git commit -m "$(cat <<'EOF'
Add Users::ShareableLinkDialogComponent

A flash-modal dialog for showing a one-time link (invitation or
password-reset) with a one-click copy button, so an admin can share
it via chat instead of relying on email. Used by two admin actions
added in later commits.
EOF
)"
```

---

## Task 5: Invitation link flow

**Files:**
- Modify: `config/routes.rb:958-965` (add route)
- Modify: `config/initializers/permissions.rb:70-79` (`create_user` permission)
- Modify: `app/controllers/users_controller.rb` (before_action list + new action)
- Modify: `app/components/users/edit_page_header_component.html.erb`
- Modify: `app/components/users/show_page_header_component.html.erb`
- Modify: `config/locales/en.yml`
- Test: `spec/controllers/users_controller_spec.rb`
- Test: `spec/features/users/copy_invitation_link_spec.rb` (new file)

**Interfaces:**
- Consumes: `UserInvitation.reinvite_user(user_id, send_notification: false)` (Task 3), `Users::ShareableLinkDialogComponent` (Task 4).
- Produces: route `invitation_link_user_path(user)` (POST), `UsersController#invitation_link`.

- [ ] **Step 1: Write the failing controller-spec test**

In `spec/controllers/users_controller_spec.rb`, immediately after the existing `describe "POST resend_invitation" do ... end` block, add:

```ruby
  describe "POST invitation_link" do
    let(:invited_user) { create(:invited_user) }

    context "without admin rights" do
      let(:normal_user) { create(:user) }

      before do
        as_logged_in_user normal_user do
          post :invitation_link, params: { id: invited_user.id }
        end
      end

      it "returns 403 forbidden" do
        expect(response).to have_http_status :forbidden
      end
    end

    context "with create_user permission rights" do
      let(:acting_user) do
        create(:user, global_permissions: %i[view_all_principals create_user manage_user])
      end

      before do
        as_logged_in_user acting_user do
          perform_enqueued_jobs do
            post :invitation_link, params: { id: invited_user.id }
          end
        end
      end

      it "redirects back to the edit user page" do
        expect(response).to redirect_to edit_user_path(invited_user)
      end

      it "does not send an email" do
        expect(ActionMailer::Base.deliveries).to be_empty
      end

      it "generates a fresh, persisted invitation token" do
        token = Token::Invitation.find_by(user_id: invited_user.id)

        expect(token).to be_present
      end

      it "flashes the shareable link dialog with the activation URL" do
        token = Token::Invitation.find_by(user_id: invited_user.id)
        modal = flash[:op_modal]

        expect(modal[:component]).to eq("Users::ShareableLinkDialogComponent")
        expect(modal[:parameters][:link]).to include("token=#{token.value}")
        expect(modal[:parameters][:link]).to include("/account/activate")
      end
    end

    context "when the target user is already active" do
      let(:active_user) { create(:user) }
      let(:acting_user) { admin }

      before do
        as_logged_in_user acting_user do
          post :invitation_link, params: { id: active_user.id }
        end
      end

      it "transitions the user to invited" do
        expect(active_user.reload).to be_invited
      end

      it "generates a token consumable via the activate action, self-registration disabled",
         with_settings: { self_registration: Setting::SelfRegistration.disabled } do
        token = Token::Invitation.find_by(user_id: active_user.id)

        get :activate, params: { token: token.value }

        expect(response).not_to redirect_to(signin_path)
      end
    end

    context "when trying to generate a link for an admin" do
      let(:affected_user) { create(:admin) }

      subject do
        as_logged_in_user acting_user do
          post :invitation_link, params: { id: affected_user.id }
        end
      end

      context "as non-admin" do
        let(:acting_user) { create(:user, global_permissions: %i[view_all_principals create_user manage_user]) }

        it "does not allow generating a link and does not touch the target" do
          subject

          expect(flash[:error]).to eq(I18n.t("user.error_admin_change_on_non_admin"))
          expect(flash[:op_modal]).to be_nil
          expect(Token::Invitation.where(user_id: affected_user.id)).to be_empty
        end
      end

      context "as admin" do
        let(:acting_user) { admin }

        it "allows generating the link" do
          subject

          expect(flash[:op_modal]).to be_present
        end
      end
    end
  end
```

Note: `admin` is already defined via `shared_let(:admin) { create(:admin) }` at the top of the file.

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/controllers/users_controller_spec.rb -e "POST invitation_link"`
Expected: FAIL — `ActionController::UrlGenerationError` / unknown action `invitation_link` (route and action don't exist yet).

- [ ] **Step 3: Add the route**

In `config/routes.rb`, inside the `resources :users do ... member do ... end end` block, change:

```ruby
    member do
      get "/hover_card" => "users/hover_card#show"
      get "/edit(/:tab)" => "users#edit", as: "edit"
      get "/change_status/:change_action" => "users#change_status_info", as: "change_status_info"
      post :change_status
      post :resend_invitation
      get :deletion_info
    end
```

to:

```ruby
    member do
      get "/hover_card" => "users/hover_card#show"
      get "/edit(/:tab)" => "users#edit", as: "edit"
      get "/change_status/:change_action" => "users#change_status_info", as: "change_status_info"
      post :change_status
      post :resend_invitation
      post :invitation_link
      get :deletion_info
    end
```

- [ ] **Step 4: Grant the permission**

In `config/initializers/permissions.rb`, change:

```ruby
      map.permission :create_user,
                     {
                       users: %i[index show new create resend_invitation],
                       "users/memberships": %i[create],
                       admin: %i[index]
                     },
                     permissible_on: :global,
                     require: :loggedin,
                     dependencies: :view_all_principals,
                     contract_actions: { users: %i[read create] }
```

to:

```ruby
      map.permission :create_user,
                     {
                       users: %i[index show new create resend_invitation invitation_link],
                       "users/memberships": %i[create],
                       admin: %i[index]
                     },
                     permissible_on: :global,
                     require: :loggedin,
                     dependencies: :view_all_principals,
                     contract_actions: { users: %i[read create] }
```

- [ ] **Step 5: Add the controller action**

In `app/controllers/users_controller.rb`, add `invitation_link` to the `find_user` before_action list:

```ruby
  before_action :find_user, only: %i[show
                                     edit
                                     update
                                     change_status_info
                                     change_status
                                     destroy
                                     deletion_info
                                     resend_invitation]
```

becomes:

```ruby
  before_action :find_user, only: %i[show
                                     edit
                                     update
                                     change_status_info
                                     change_status
                                     destroy
                                     deletion_info
                                     resend_invitation
                                     invitation_link]
```

Then add the action itself, directly after the existing `resend_invitation` method:

```ruby
  def invitation_link # rubocop:disable Metrics/AbcSize
    if @user.admin? && !current_user.admin?
      # non-admin users are not allowed to change admin status
      flash[:error] = I18n.t("user.error_admin_change_on_non_admin")
      redirect_to helpers.allowed_management_user_profile_path(@user)
      return
    end

    status = Principal.statuses[:invited]
    @user.update!(status: status) if @user.status != status

    token = UserInvitation.reinvite_user(@user.id, send_notification: false)

    if token.persisted?
      link = url_for(controller: "/account", action: :activate, token: token.value)
      flash_op_modal component: Users::ShareableLinkDialogComponent,
                      parameters: {
                        link:,
                        title: I18n.t(:label_invitation_link_dialog_title),
                        description: I18n.t(:text_invitation_link_dialog_description)
                      }
    else
      logger.error "could not generate invitation link for #{@user.mail}: #{token.errors.full_messages.join(' ')}"
      flash[:error] = I18n.t(:notice_internal_server_error, app_title: Setting.app_title)
    end

    redirect_to helpers.allowed_management_user_profile_path(@user)
  end
```

- [ ] **Step 6: Add locale strings**

In `config/locales/en.yml`, near the existing `label_send_invitation: Send invitation` line, add:

```yaml
  label_copy_invitation_link: "Copy invitation link"
  label_invitation_link_dialog_title: "Invitation link"
```

Near the existing `tooltip_resend_invitation:` block, add:

```yaml
  tooltip_copy_invitation_link: >
    Generates a fresh activation link and shows it so you can copy and share it directly
    (e.g. via a chat app), without sending an email. When used with active users their
    status will be changed to 'invited'.
  text_invitation_link_dialog_description: >
    Share this link with the user so they can activate their account and choose a password.
```

- [ ] **Step 7: Add the "Copy invitation link" button**

In `app/components/users/edit_page_header_component.html.erb`, immediately after the existing "Send invitation" `header.with_action_button` block (the one with `href: resend_invitation_user_path(@user)`), add:

```erb
    if @current_user.allowed_globally?(:create_user) && @current_user.id != @user.id
      header.with_action_button(
        tag: :a,
        mobile_icon: :copy,
        mobile_label: t(:label_copy_invitation_link),
        size: :medium,
        href: invitation_link_user_path(@user),
        data: { turbo_method: :post },
        aria: { label: I18n.t(:label_copy_invitation_link) },
        title: I18n.t(:tooltip_copy_invitation_link)
      ) do |button|
        button.with_leading_visual_icon(icon: :copy)
        t(:label_copy_invitation_link)
      end
    end
```

Do the same in `app/components/users/show_page_header_component.html.erb`, after its "Send invitation" block (guard there uses `@current_user != @user`, matching the file's existing style):

```erb
    if @current_user.allowed_globally?(:create_user) && @current_user != @user
      header.with_action_button(
        tag: :a,
        mobile_icon: :copy,
        mobile_label: t(:label_copy_invitation_link),
        size: :medium,
        href: invitation_link_user_path(@user),
        data: { turbo_method: :post },
        aria: { label: I18n.t(:label_copy_invitation_link) },
        title: I18n.t(:tooltip_copy_invitation_link)
      ) do |button|
        button.with_leading_visual_icon(icon: :copy)
        t(:label_copy_invitation_link)
      end
    end
```

- [ ] **Step 8: Run test to verify it passes**

Run: `bundle exec rspec spec/controllers/users_controller_spec.rb -e "POST invitation_link"`
Expected: PASS (9 examples)

Run: `bundle exec rspec spec/controllers/users_controller_spec.rb`
Expected: PASS (no regressions)

- [ ] **Step 9: Write and run the feature spec**

Create `spec/features/users/copy_invitation_link_spec.rb`:

```ruby
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

require "spec_helper"

RSpec.describe "Copying an invitation link", :js do
  shared_let(:admin) { create(:admin) }
  shared_let(:invited_user) { create(:invited_user) }

  before do
    login_as admin
  end

  it "opens a dialog with the activation link, without sending an email" do
    visit edit_user_path(invited_user)

    perform_enqueued_jobs do
      click_link "Copy invitation link"
    end

    expect(page).to have_css("dialog##{Users::ShareableLinkDialogComponent::DIALOG_ID}", visible: true)

    token = Token::Invitation.find_by(user_id: invited_user.id)
    expect(page).to have_css(
      "clipboard-copy[value*='/account/activate'][value*='token=#{token.value}']",
      visible: true
    )
    expect(ActionMailer::Base.deliveries).to be_empty
  end

  context "when a regular user without create_user views their own profile" do
    let(:user) { create(:user) }

    before do
      login_as user
    end

    it "does not show the button" do
      visit user_path(user)

      expect(page).to have_no_link("Copy invitation link")
    end
  end
end
```

Run: `bundle exec rspec spec/features/users/copy_invitation_link_spec.rb`
Expected: PASS (2 examples)

- [ ] **Step 10: Commit**

```bash
git add config/routes.rb config/initializers/permissions.rb app/controllers/users_controller.rb \
        app/components/users/edit_page_header_component.html.erb \
        app/components/users/show_page_header_component.html.erb \
        config/locales/en.yml \
        spec/controllers/users_controller_spec.rb \
        spec/features/users/copy_invitation_link_spec.rb
git commit -m "$(cat <<'EOF'
Let admins copy an invitation link instead of only emailing it

Adds UsersController#invitation_link, mirroring resend_invitation's
admin-target guard and invited-status transition, but skipping the
notification and instead showing the link in a copyable dialog.
EOF
)"
```

---

## Task 6: Admin-issued password-reset link flow

**Files:**
- Modify: `config/routes.rb` (add route)
- Modify: `config/initializers/permissions.rb` (`manage_user` permission)
- Modify: `app/controllers/users_controller.rb` (before_action list + new action)
- Modify: `app/components/users/edit_page_header_component.html.erb`
- Modify: `app/components/users/show_page_header_component.html.erb`
- Modify: `config/locales/en.yml`
- Test: `spec/controllers/users_controller_spec.rb`
- Test: `spec/features/users/copy_password_reset_link_spec.rb` (new file)

**Interfaces:**
- Consumes: `Token::Recovery::CHANNEL_CHAT_LINK` (Task 1), `Users::ShareableLinkDialogComponent` (Task 4).
- Produces: route `password_reset_link_user_path(user)` (POST), `UsersController#password_reset_link`.

- [ ] **Step 1: Write the failing controller-spec test**

In `spec/controllers/users_controller_spec.rb`, after the `describe "POST invitation_link" do ... end` block added in Task 5, add:

```ruby
  describe "POST password_reset_link" do
    let(:active_user) { create(:user) }

    context "without manage_user rights" do
      let(:normal_user) { create(:user) }

      before do
        as_logged_in_user normal_user do
          post :password_reset_link, params: { id: active_user.id }
        end
      end

      it "returns 403 forbidden" do
        expect(response).to have_http_status :forbidden
      end
    end

    context "with manage_user permission rights" do
      let(:acting_user) do
        create(:user, global_permissions: %i[view_all_principals manage_user])
      end

      before do
        as_logged_in_user acting_user do
          post :password_reset_link, params: { id: active_user.id }
        end
      end

      it "redirects back to the edit user page" do
        expect(response).to redirect_to edit_user_path(active_user)
      end

      it "does not send an email" do
        expect(ActionMailer::Base.deliveries).to be_empty
      end

      it "creates a Token::Recovery marked as a chat link" do
        token = Token::Recovery.find_by(user_id: active_user.id)

        expect(token).to be_present
        expect(token.data["channel"]).to eq(Token::Recovery::CHANNEL_CHAT_LINK)
      end

      it "flashes the shareable link dialog with the lost_password URL" do
        token = Token::Recovery.find_by(user_id: active_user.id)
        modal = flash[:op_modal]

        expect(modal[:component]).to eq("Users::ShareableLinkDialogComponent")
        expect(modal[:parameters][:link]).to include("token=#{token.value}")
        expect(modal[:parameters][:link]).to include("/account/lost_password")
      end
    end

    context "when the target user is locked" do
      let(:acting_user) { admin }
      let(:locked_user) { create(:locked_user) }

      before do
        as_logged_in_user acting_user do
          post :password_reset_link, params: { id: locked_user.id }
        end
      end

      it "does not create a token" do
        expect(Token::Recovery.where(user_id: locked_user.id)).to be_empty
      end

      it "flashes an error instead of the dialog" do
        expect(flash[:op_modal]).to be_nil
        expect(flash[:error]).to eq(I18n.t("user.error_password_reset_link_not_allowed"))
      end
    end

    context "when the target user authenticates via LDAP" do
      let(:acting_user) { admin }
      let(:ldap_user) { create(:user, ldap_auth_source: create(:ldap_auth_source)) }

      before do
        as_logged_in_user acting_user do
          post :password_reset_link, params: { id: ldap_user.id }
        end
      end

      it "does not create a token" do
        expect(Token::Recovery.where(user_id: ldap_user.id)).to be_empty
      end

      it "flashes an error instead of the dialog" do
        expect(flash[:op_modal]).to be_nil
        expect(flash[:error]).to eq(I18n.t("user.error_password_reset_link_not_allowed"))
      end
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/controllers/users_controller_spec.rb -e "POST password_reset_link"`
Expected: FAIL — unknown action `password_reset_link`.

- [ ] **Step 3: Add the route**

In `config/routes.rb`, extend the same `member do ... end` block touched in Task 5:

```ruby
    member do
      get "/hover_card" => "users/hover_card#show"
      get "/edit(/:tab)" => "users#edit", as: "edit"
      get "/change_status/:change_action" => "users#change_status_info", as: "change_status_info"
      post :change_status
      post :resend_invitation
      post :invitation_link
      post :password_reset_link
      get :deletion_info
    end
```

- [ ] **Step 4: Grant the permission**

In `config/initializers/permissions.rb`, change:

```ruby
      map.permission :manage_user,
                     {
                       users: %i[index show edit update change_status change_status_info],
                       "users/memberships": %i[create update destroy],
                       admin: %i[index]
                     },
                     permissible_on: :global,
                     require: :loggedin,
                     dependencies: :view_all_principals,
                     contract_actions: { users: %i[read update] }
```

to:

```ruby
      map.permission :manage_user,
                     {
                       users: %i[index show edit update change_status change_status_info password_reset_link],
                       "users/memberships": %i[create update destroy],
                       admin: %i[index]
                     },
                     permissible_on: :global,
                     require: :loggedin,
                     dependencies: :view_all_principals,
                     contract_actions: { users: %i[read update] }
```

- [ ] **Step 5: Add the controller action**

In `app/controllers/users_controller.rb`, add `password_reset_link` to the `find_user` before_action list (extending the list from Task 5):

```ruby
  before_action :find_user, only: %i[show
                                     edit
                                     update
                                     change_status_info
                                     change_status
                                     destroy
                                     deletion_info
                                     resend_invitation
                                     invitation_link
                                     password_reset_link]
```

Then add the action itself, directly after `invitation_link`:

```ruby
  def password_reset_link
    unless @user.active? && @user.change_password_allowed?
      flash[:error] = I18n.t("user.error_password_reset_link_not_allowed")
      redirect_to helpers.allowed_management_user_profile_path(@user)
      return
    end

    token = Token::Recovery.new(user_id: @user.id, data: { channel: Token::Recovery::CHANNEL_CHAT_LINK })

    if token.save
      link = url_for(controller: "/account", action: :lost_password, token: token.value)
      flash_op_modal component: Users::ShareableLinkDialogComponent,
                      parameters: {
                        link:,
                        title: I18n.t(:label_password_reset_link_dialog_title),
                        description: I18n.t(:text_password_reset_link_dialog_description)
                      }
    else
      logger.error "could not generate password reset link for #{@user.mail}: #{token.errors.full_messages.join(' ')}"
      flash[:error] = I18n.t(:notice_internal_server_error, app_title: Setting.app_title)
    end

    redirect_to helpers.allowed_management_user_profile_path(@user)
  end
```

- [ ] **Step 6: Add locale strings**

In `config/locales/en.yml`, near the `label_copy_invitation_link` line added in Task 5, add:

```yaml
  label_copy_password_reset_link: "Copy password reset link"
  label_password_reset_link_dialog_title: "Password reset link"
```

Near the `tooltip_copy_invitation_link` block added in Task 5, add:

```yaml
  tooltip_copy_password_reset_link: >
    Generates a link the user can use to set a new password, and shows it so you can
    copy and share it directly (e.g. via a chat app) instead of email.
  text_password_reset_link_dialog_description: >
    Share this link with the user so they can set a new password. It expires after 1 day.
```

In the `user:` nested block, near `error_admin_change_on_non_admin:`, add:

```yaml
    error_password_reset_link_not_allowed: >
      A password reset link cannot be generated for this user (they must be active and
      allowed to change their password).
```

- [ ] **Step 7: Add the "Copy password reset link" button**

In `app/components/users/edit_page_header_component.html.erb`, after the "Copy invitation link" block added in Task 5, add:

```erb
    if @current_user.allowed_globally?(:manage_user) && @user.active? && @user.change_password_allowed?
      header.with_action_button(
        tag: :a,
        mobile_icon: :key,
        mobile_label: t(:label_copy_password_reset_link),
        size: :medium,
        href: password_reset_link_user_path(@user),
        data: { turbo_method: :post },
        aria: { label: I18n.t(:label_copy_password_reset_link) },
        title: I18n.t(:tooltip_copy_password_reset_link)
      ) do |button|
        button.with_leading_visual_icon(icon: :key)
        t(:label_copy_password_reset_link)
      end
    end
```

Do the same in `app/components/users/show_page_header_component.html.erb`, after its "Copy invitation link" block:

```erb
    if @current_user.allowed_globally?(:manage_user) && @user.active? && @user.change_password_allowed?
      header.with_action_button(
        tag: :a,
        mobile_icon: :key,
        mobile_label: t(:label_copy_password_reset_link),
        size: :medium,
        href: password_reset_link_user_path(@user),
        data: { turbo_method: :post },
        aria: { label: I18n.t(:label_copy_password_reset_link) },
        title: I18n.t(:tooltip_copy_password_reset_link)
      ) do |button|
        button.with_leading_visual_icon(icon: :key)
        t(:label_copy_password_reset_link)
      end
    end
```

Note: this button's guard already includes `@current_user.allowed_globally?(:manage_user)` — required because `show_page_header_component` also renders for ordinary users viewing any visible profile (`UsersController#show` is `no_authorization_required!`), so the permission check must be explicit here rather than assumed from context.

- [ ] **Step 8: Run test to verify it passes**

Run: `bundle exec rspec spec/controllers/users_controller_spec.rb -e "POST password_reset_link"`
Expected: PASS (9 examples)

Run: `bundle exec rspec spec/controllers/users_controller_spec.rb`
Expected: PASS (no regressions)

- [ ] **Step 9: Write and run the feature spec**

Create `spec/features/users/copy_password_reset_link_spec.rb`:

```ruby
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

require "spec_helper"

RSpec.describe "Copying a password reset link", :js do
  shared_let(:admin) { create(:admin) }
  shared_let(:active_user) { create(:user) }

  before do
    login_as admin
  end

  it "opens a dialog with the lost_password link, without sending an email" do
    visit edit_user_path(active_user)

    perform_enqueued_jobs do
      click_link "Copy password reset link"
    end

    expect(page).to have_css("dialog##{Users::ShareableLinkDialogComponent::DIALOG_ID}", visible: true)

    token = Token::Recovery.find_by(user_id: active_user.id)
    expect(page).to have_css(
      "clipboard-copy[value*='/account/lost_password'][value*='token=#{token.value}']",
      visible: true
    )
    expect(ActionMailer::Base.deliveries).to be_empty
  end

  context "when the viewer only has create_user, not manage_user" do
    let(:create_user_only) { create(:user, global_permissions: %i[view_all_principals create_user]) }

    before do
      login_as create_user_only
    end

    it "does not show the button" do
      visit user_path(active_user)

      expect(page).to have_no_link("Copy password reset link")
    end
  end

  context "when the target user is locked" do
    let(:locked_user) { create(:locked_user) }

    it "does not show the button" do
      visit user_path(locked_user)

      expect(page).to have_no_link("Copy password reset link")
    end
  end
end
```

Run: `bundle exec rspec spec/features/users/copy_password_reset_link_spec.rb`
Expected: PASS (3 examples)

- [ ] **Step 10: Commit**

```bash
git add config/routes.rb config/initializers/permissions.rb app/controllers/users_controller.rb \
        app/components/users/edit_page_header_component.html.erb \
        app/components/users/show_page_header_component.html.erb \
        config/locales/en.yml \
        spec/controllers/users_controller_spec.rb \
        spec/features/users/copy_password_reset_link_spec.rb
git commit -m "$(cat <<'EOF'
Let admins copy a password-reset link instead of only emailing it

Adds UsersController#password_reset_link, gated on manage_user and
re-checking active?/change_password_allowed? server-side (not just
in the button's visibility guard). Reuses the existing
account/lost_password consumption flow untouched; the token is
marked with the chat_link channel added in an earlier commit so it
gets the shorter 1-day validity.
EOF
)"
```

---

## Final check

After all six tasks:

- [ ] Run the full affected suite once more to catch cross-task regressions:

```bash
bundle exec rspec \
  spec/models/token/recovery_spec.rb \
  spec/controllers/account_controller_spec.rb \
  spec/controllers/concerns/user_invitation_spec.rb \
  spec/components/users/shareable_link_dialog_component_spec.rb \
  spec/controllers/users_controller_spec.rb \
  spec/features/users/copy_invitation_link_spec.rb \
  spec/features/users/copy_password_reset_link_spec.rb
```

- [ ] Run Rubocop on all touched Ruby files: `bundle exec rubocop app/controllers/users_controller.rb app/controllers/account_controller.rb app/controllers/concerns/user_invitation.rb app/models/token/recovery.rb app/components/users/shareable_link_dialog_component.rb`
- [ ] Run erb_lint on the new/changed ERB: `erb_lint app/components/users/shareable_link_dialog_component.html.erb app/components/users/edit_page_header_component.html.erb app/components/users/show_page_header_component.html.erb`
