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

RSpec.describe "GET /api/v3/attachments/:id/thumbnail", content_type: :json do
  include Rack::Test::Methods
  include API::V3::Utilities::PathHelper
  include FileHelpers

  shared_let(:project) { create(:project, public: false) }
  shared_let(:role) { create(:project_role, permissions: %i[view_work_packages edit_work_packages]) }
  shared_let(:current_user) { create(:user, member_with_roles: { project => role }) }
  shared_let(:work_package) { create(:work_package, project:) }

  let(:attachment) do
    create(:attachment, container: work_package, author: current_user, content_type: nil,
                        file: create(:uploaded_jpg, name: "picture.jpg"))
  end
  let(:path) { api_v3_paths.attachment_thumbnail attachment.id }

  subject(:response) { last_response }

  before do
    allow(User).to receive(:current).and_return current_user
  end

  # Writes a fake (non-image) WebP file straight to the variant path so the
  # serving behaviour can be exercised without ImageMagick.
  def write_ready_thumbnail!
    FileUtils.mkdir_p(attachment.thumbnail_path.dirname)
    File.binwrite(attachment.thumbnail_path, "RIFF....WEBPfake-bytes")
    attachment.update_column(:thumbnail_status, "ready")
  end

  after { FileUtils.rm_rf(attachment.thumbnails_directory) }

  context "when a thumbnail is ready" do
    before do
      write_ready_thumbnail!
      get path
    end

    it "responds 200 with WebP, inline disposition, nosniff and an immutable cache" do
      expect(response).to have_http_status 200
      expect(response.headers["Content-Type"]).to eq "image/webp"
      expect(response.headers["Content-Disposition"]).to eq "inline"
      expect(response.headers["X-Content-Type-Options"]).to eq "nosniff"
      expect(response.headers["Cache-Control"]).to eq "public, max-age=31536000, immutable"
      expect(response.headers["ETag"]).to eq %("#{attachment.digest}")
    end
  end

  context "when the thumbnail is missing but generatable (lazy path)" do
    before do
      allow(Attachments::ThumbnailGenerator).to receive(:new) do |att|
        instance_double(Attachments::ThumbnailGenerator).tap do |generator|
          allow(generator).to receive(:call) do
            FileUtils.mkdir_p(att.thumbnail_path.dirname)
            File.binwrite(att.thumbnail_path, "RIFF....WEBPfake-bytes")
            :ready
          end
        end
      end

      get path
    end

    it "lazily generates and serves the thumbnail" do
      expect(response).to have_http_status 200
      expect(response.headers["Content-Type"]).to eq "image/webp"
      expect(attachment.reload.thumbnail_status).to eq "ready"
    end
  end

  context "when generation already failed (status error)" do
    before do
      attachment.update_column(:thumbnail_status, "error")
      get path
    end

    it "responds 404 and does not retry generation" do
      expect(response).to have_http_status 404
    end
  end

  context "when the attachment is not thumbnailable" do
    let(:attachment) do
      create(:attachment, container: work_package, author: current_user,
                          file: FileHelpers.mock_uploaded_file(name: "notes.txt"))
    end

    before { get path }

    it "responds 404" do
      expect(response).to have_http_status 404
    end
  end

  context "when thumbnails are disabled", with_config: { attachments_thumbnails_enabled: false } do
    before do
      attachment.update_column(:thumbnail_status, "ready")
      get path
    end

    it "responds 404" do
      expect(response).to have_http_status 404
    end
  end

  context "when the attachment is quarantined" do
    before do
      write_ready_thumbnail!
      attachment.update_column(:status, Attachment.statuses[:quarantined])
      get path
    end

    it "responds 404 without leaking the preview" do
      expect(response).to have_http_status 404
    end
  end

  context "when the attachment is not visible to the user" do
    before do
      allow_any_instance_of(Attachment).to receive(:visible?).and_return(false) # rubocop:disable RSpec/AnyInstance
      get path
    end

    it "responds 404" do
      expect(response).to have_http_status 404
    end
  end

  context "when the attachment does not exist" do
    let(:path) { api_v3_paths.attachment_thumbnail 9999 }

    before { get path }

    it "responds 404" do
      expect(response).to have_http_status 404
    end
  end
end
