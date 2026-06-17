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

RSpec.describe Attachments::GenerateThumbnailJob, type: :job do
  shared_let(:author) { create(:user) }
  shared_let(:work_package) { create(:work_package) }

  let(:attachment) do
    create(:attachment, author:, container: work_package, content_type: nil, file: create(:uploaded_jpg))
  end

  subject(:perform) { described_class.new.perform(attachment.id) }

  before do
    allow(Attachment).to receive(:find_by).with(id: attachment.id).and_return(attachment)
    allow(attachment).to receive(:generate_thumbnail!).and_return(true)
  end

  context "when the attachment is thumbnailable and scanned" do
    before { allow(attachment).to receive(:thumbnailable?).and_return(true) }

    it "generates the thumbnail" do
      perform

      expect(attachment).to have_received(:generate_thumbnail!)
    end

    it "skips generation when a thumbnail already exists on disk" do
      allow(attachment).to receive(:thumbnail_ready?).and_return(true)
      allow(File).to receive(:exist?).with(attachment.thumbnail_path).and_return(true)

      perform

      expect(attachment).not_to have_received(:generate_thumbnail!)
    end
  end

  context "when the attachment is not thumbnailable" do
    before { allow(attachment).to receive(:thumbnailable?).and_return(false) }

    it "does nothing" do
      perform

      expect(attachment).not_to have_received(:generate_thumbnail!)
    end
  end

  context "when the attachment is quarantined" do
    before do
      allow(attachment).to receive_messages(thumbnailable?: true, status_quarantined?: true)
    end

    it "does not generate a thumbnail" do
      perform

      expect(attachment).not_to have_received(:generate_thumbnail!)
    end
  end

  context "when the attachment is still pending a virus scan" do
    before do
      allow(attachment).to receive_messages(thumbnailable?: true, pending_virus_scan?: true)
    end

    it "does not generate a thumbnail" do
      perform

      expect(attachment).not_to have_received(:generate_thumbnail!)
    end
  end

  context "when the attachment no longer exists" do
    before { allow(Attachment).to receive(:find_by).with(id: 0).and_return(nil) }

    it "returns without error" do
      expect { described_class.new.perform(0) }.not_to raise_error
    end
  end
end
