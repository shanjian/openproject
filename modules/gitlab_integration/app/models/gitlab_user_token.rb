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

# A user's GitLab Personal Access Token (needs the `api` scope).
#
# The token is a write-capable credential, so it is *always* encrypted at rest,
# independent of the optional `database_cipher_key` setting: we use
# ActiveSupport::MessageEncryptor (AES-256-GCM) with a key derived from the
# application's `secret_key_base` (which is always present). This deliberately
# does NOT use Redmine::Ciphering, because that falls back to plaintext when no
# database cipher key is configured. The token is never exposed to the frontend.
# See GITLAB_CREATE_BRANCH_DESIGN.md §2.3.
class GitlabUserToken < ApplicationRecord
  ENCRYPTOR_PURPOSE = "gitlab_integration/user_token"

  belongs_to :user

  validates :user_id, uniqueness: true
  validates :token, presence: true

  class << self
    def encryptor
      @encryptor ||= begin
        len = ActiveSupport::MessageEncryptor.key_len
        key = ActiveSupport::KeyGenerator
                .new(Rails.application.secret_key_base)
                .generate_key(ENCRYPTOR_PURPOSE, len)
        ActiveSupport::MessageEncryptor.new(key)
      end
    end
  end

  def token
    encrypted = self[:token]
    return if encrypted.blank?

    self.class.encryptor.decrypt_and_verify(encrypted)
  rescue ActiveSupport::MessageEncryptor::InvalidMessage
    nil
  end

  def token=(value)
    stripped = value.presence&.strip
    self[:token] = stripped && self.class.encryptor.encrypt_and_sign(stripped)
  end
end
