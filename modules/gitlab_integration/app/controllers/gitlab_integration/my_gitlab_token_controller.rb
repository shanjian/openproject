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

module GitlabIntegration
  # "My account" page where each user stores their own GitLab Personal Access
  # Token (needs the `api` scope). The token is only ever written,
  # never rendered back to the browser.
  class MyGitlabTokenController < ::ApplicationController
    before_action :require_login
    menu_item :gitlab_token
    layout "my"

    no_authorization_required! :show, :update, :destroy

    def show
      @token_record = token_record
    end

    def update
      record = token_record
      record.token = params.expect(gitlab_user_token: [:token])[:token]

      if record.save
        flash[:notice] = I18n.t(:notice_successful_update)
      else
        flash[:error] = record.errors.full_messages.join(", ")
      end

      redirect_to my_gitlab_token_path
    end

    def destroy
      token_record.destroy!
      flash[:notice] = I18n.t("gitlab_integration.my_token.removed")
      redirect_to my_gitlab_token_path
    end

    private

    def token_record
      GitlabUserToken.find_or_initialize_by(user_id: current_user.id)
    end
  end
end
