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

RSpec.describe Attachment do
  let(:stubbed_author) { build_stubbed(:user) }
  let(:author) { create(:user) }
  let(:long_description) { "a" * 300 }
  let(:work_package) { create(:work_package) }
  let(:stubbed_work_package) { build_stubbed(:work_package) }
  let(:file) { create(:uploaded_jpg, name: "test.jpg") }
  let(:second_file) { create(:uploaded_jpg, name: "test2.jpg") }
  let(:container) { stubbed_work_package }

  let(:attachment) do
    build(
      :attachment,
      author:,
      container:,
      content_type: nil, # so that it is detected
      file:
    )
  end
  let(:stubbed_attachment) do
    build_stubbed(
      :attachment,
      author: stubbed_author,
      container:
    )
  end

  describe "validations" do
    it "is valid" do
      expect(stubbed_attachment)
        .to be_valid
    end

    context "with a long description" do
      before do
        stubbed_attachment.description = long_description
        stubbed_attachment.valid?
      end

      it "raises an error regarding description length" do
        expect(stubbed_attachment.errors[:description])
          .to contain_exactly(I18n.t("activerecord.errors.messages.too_long", count: 255))
      end
    end

    context "without a container" do
      let(:container) { nil }

      it "is valid" do
        expect(stubbed_attachment)
          .to be_valid
      end
    end

    context "without a container first and then setting a container" do
      let(:container) { nil }

      before do
        stubbed_attachment.container = work_package
      end

      it "is valid" do
        expect(stubbed_attachment)
          .to be_valid
      end
    end

    context "with a container first and then removing the container" do
      before do
        stubbed_attachment.container = nil
      end

      it "notes the field as unchangeable" do
        stubbed_attachment.valid?

        expect(stubbed_attachment.errors.symbols_for(:container))
          .to contain_exactly(:unchangeable)
      end
    end

    context "with a container first and then changing the container_id" do
      before do
        stubbed_attachment.container_id = stubbed_attachment.container_id + 1
      end

      it "notes the field as unchangeable" do
        stubbed_attachment.valid?

        expect(stubbed_attachment.errors.symbols_for(:container))
          .to contain_exactly(:unchangeable)
      end
    end

    context "with a container first and then changing the container_type" do
      before do
        stubbed_attachment.container_type = "WikiPage"
      end

      it "notes the field as unchangeable" do
        stubbed_attachment.valid?

        expect(stubbed_attachment.errors.symbols_for(:container))
          .to contain_exactly(:unchangeable)
      end
    end
  end

  describe "#containered?" do
    it "is false if the attachment has no container" do
      stubbed_attachment.container = nil

      expect(stubbed_attachment)
        .not_to be_containered
    end

    it "is true if the attachment has a container" do
      expect(stubbed_attachment)
        .to be_containered
    end
  end

  describe "create" do
    it("creates a jpg file called test") do
      expect(File.exist?(attachment.diskfile.path)).to be true
    end

    it('has the content type "image/jpeg"') do
      expect(attachment.content_type).to eq "image/jpeg"
    end

    it "has the correct filesize" do
      expect(attachment.filesize)
        .to eql file.size
    end

    it "creates an md5 digest" do
      expect(attachment.digest)
        .to eql Digest::MD5.file(file.path).hexdigest
    end
  end

  describe "content type detection" do
    context "with an SVG file uploaded with .png extension" do
      let(:svg_content) do
        <<~SVG
          <?xml version="1.0" encoding="UTF-8"?>
          <svg width="600" height="600" xmlns="http://www.w3.org/2000/svg">
          <image href="text:/etc/passwd" width="600" height="600" />
          </svg>
        SVG
      end
      let(:svg_file) { FileHelpers.mock_uploaded_file(name: "test.png", content: svg_content, binary: false) }
      let(:svg_attachment) do
        build(
          :attachment,
          author:,
          container:,
          content_type: "image/png", # This should be overridden by actual file content detection
          file: svg_file
        )
      end

      it "correctly detects the content type as SVG based on file content, not filename" do
        expect(svg_attachment.content_type).to eq "image/svg+xml"
      end

      it "does not allow SVG content type to be misidentified as image/png" do
        expect(svg_attachment.content_type).not_to eq "image/png"
      end

      it "relies on file content detection, not filename-based narrowing" do
        detected_type = described_class.content_type_for(svg_file.path)
        expect(detected_type).to eq "image/svg+xml"
      end
    end
  end

  describe ".content_type_for" do
    let(:detector) { instance_double(OpenProject::ContentTypeDetector) }

    before do
      allow(OpenProject::ContentTypeDetector).to receive(:new).and_return(detector)
    end

    context "when content detection returns a generic binary type" do
      before { allow(detector).to receive(:detect).and_return("application/octet-stream") }

      it "falls back to the video MIME implied by a video extension" do
        expect(described_class.content_type_for("/tmp/clip.mp4")).to eq "video/mp4"
      end

      it "keeps the generic type for a non-video extension" do
        expect(described_class.content_type_for("/tmp/archive.bin")).to eq "application/octet-stream"
      end
    end

    context "when content detection returns a specific type" do
      before { allow(detector).to receive(:detect).and_return("image/svg+xml") }

      it "never overrides it based on the extension (preserves content-based detection)" do
        expect(described_class.content_type_for("/tmp/sneaky.mp4")).to eq "image/svg+xml"
      end
    end
  end

  describe ".redetect_generic_content_types" do
    let!(:generic_video) do
      described_class.create!(container: work_package, author:,
                              file: FileHelpers.mock_uploaded_file(name: "clip.mp4"))
                     .tap { |a| a.update_columns(content_type: "application/octet-stream") }
    end

    it "re-detects generic-typed attachments via the extension fallback" do
      allow(OpenProject::ContentTypeDetector)
        .to receive(:new)
        .and_return(instance_double(OpenProject::ContentTypeDetector, detect: "application/octet-stream"))

      expect { described_class.redetect_generic_content_types }
        .to change { generic_video.reload.content_type }
        .from("application/octet-stream").to("video/mp4")
    end
  end

  describe "two attachments with same file name" do
    let(:second_file) { create(:uploaded_jpg, name: file.original_filename) }

    it "does not interfere" do
      a1 = Attachment.create!(container: work_package,
                              file:,
                              author:)
      a2 = Attachment.create!(container: work_package,
                              file: second_file,
                              author:)

      expect(a1.diskfile.path)
        .not_to eql a2.diskfile.path
    end
  end

  ##
  # The tests assumes the default, file-based storage is configured and tests against that.
  # I.e. it does not test fog attachments being deleted from the cloud storage (such as S3).
  describe "#destroy" do
    before do
      attachment.save!

      expect(File.exist?(attachment.file.path)).to be true

      attachment.destroy
      attachment.run_callbacks(:commit)
      # triggering after_commit callbacks manually as they are not triggered during rspec runs
      # though in dev/production mode destroy does trigger these callbacks
    end

    it "deletes the attachment's file" do
      expect(File.exist?(attachment.file.path)).to be false
    end
  end

  it_behaves_like "creates an audit trail on destroy" do
    subject { create(:attachment) }
  end

  # We just use with_direct_uploads here to make sure the
  # FogAttachment class is defined and Fog is mocked.
  describe "#external_url", :with_direct_uploads do
    let(:author) { create(:user) }

    let(:image_path) { Rails.root.join("spec/fixtures/files/image.png") }
    let(:text_path) { Rails.root.join("spec/fixtures/files/testfile.txt") }
    let(:binary_path) { Rails.root.join("spec/fixtures/files/textfile.txt.gz") }

    let(:image_attachment) { FogAttachment.new author:, file: File.open(image_path) }
    let(:text_attachment) { FogAttachment.new author:, file: File.open(text_path) }
    let(:binary_attachment) { FogAttachment.new author:, file: File.open(binary_path) }

    shared_examples "it has a temporary download link" do
      let(:url_options) { {} }
      let(:query) { attachment.external_url(**url_options).to_s.split("?").last }

      it "has a default expiration time" do
        expect(query).to include "X-Amz-Expires="
        expect(query).not_to include "X-Amz-Expires=3600"
      end

      context "with a custom expiration time" do
        let(:url_options) { { expires_in: 1.hour } }

        it "uses that time" do
          expect(query).to include "X-Amz-Expires=3600"
        end
      end

      context "with expiration time exceeding maximum" do
        let(:url_options) { { expires_in: 1.year } }

        it "uses the allowed max" do
          expect(query).to include "X-Amz-Expires=#{OpenProject::Configuration.fog_download_url_expires_in}"
        end
      end
    end

    shared_examples "it uses content disposition inline" do
      let(:attachment) { raise "define me!" }

      describe "the external url (for remote attachments)" do
        it "contains inline content disposition without the filename" do
          expect(attachment.external_url.to_s).to include "response-content-disposition=inline&"
        end
      end

      describe "content disposition (for local attachments)" do
        it "is inline, including the filename" do
          expect(attachment.content_disposition).to eq "inline; filename=#{attachment.filename}"
        end
      end
    end

    describe "for an image file" do
      before { image_attachment.save! }

      it_behaves_like "it uses content disposition inline" do
        let(:attachment) { image_attachment }
      end

      # this is independent from the type of file uploaded so we just test this for the first one
      it_behaves_like "it has a temporary download link" do
        let(:attachment) { image_attachment }
      end
    end

    describe "for a text file" do
      before { text_attachment.save! }

      it_behaves_like "it uses content disposition inline" do
        let(:attachment) { text_attachment }
      end
    end

    describe "for a video file" do
      let(:attachment) { described_class.new }

      it "assumes it to be inlineable" do
        %w[video/webm video/mp4 video/quicktime].each do |content_type|
          attachment.content_type = content_type
          expect(attachment).to be_inlineable, "#{content_type} should be inlineable"
        end
      end
    end

    describe "for an HTML file" do
      let(:attachment) { described_class.new }

      it "assumes it not to be inlineable" do
        attachment.content_type = "text/html"
        expect(attachment).to be_is_html
        expect(attachment).not_to be_is_text
        expect(attachment).not_to be_inlineable
      end
    end

    describe "for a binary file" do
      before { binary_attachment.save! }

      it "makes S3 use content_disposition 'attachment; filename=...'" do
        expect(binary_attachment.content_disposition).to eq "attachment; filename=textfile.txt.gz"
        expect(binary_attachment.external_url.to_s).to include "response-content-disposition=attachment"
      end
    end
  end

  describe "virus scan job on commit" do
    shared_let(:work_package) { create(:work_package) }
    let(:created_attachment) do
      create(:attachment,
             status: :uploaded,
             container: work_package)
    end

    context "with setting disabled", with_settings: { antivirus_scan_mode: :disabled } do
      it "does not run" do
        attachment.save
        expect(attachment.pending_virus_scan?).to be false

        expect(Attachments::VirusScanJob)
          .not_to have_been_enqueued.with(attachment)
      end
    end

    context "with setting enabled",
            with_ee: %i[virus_scanning],
            with_settings: { antivirus_scan_mode: :clamav_socket } do
      it "runs the job" do
        attachment.save
        expect(attachment.pending_virus_scan?).to be true

        expect(Attachments::VirusScanJob)
          .to have_been_enqueued.with(attachment)
      end
    end
  end

  describe "full text extraction job on commit" do
    let(:created_attachment) do
      create(:attachment,
             author:,
             container:)
    end

    shared_examples_for "runs extraction" do
      it "runs extraction" do
        extraction_with_id = nil

        allow(Attachments::ExtractFulltextJob)
          .to receive(:perform_later) do |id|
          extraction_with_id = id
        end

        attachment.save

        expect(extraction_with_id).to eql attachment.id
      end
    end

    shared_examples_for "does not run extraction" do
      it "does not run extraction" do
        created_attachment

        expect(Attachments::ExtractFulltextJob)
          .not_to receive(:perform_later)

        created_attachment.save
      end
    end

    context "for a work package" do
      let(:work_package) { create(:work_package) }
      let(:container) { work_package }

      context "on create" do
        it_behaves_like "runs extraction"
      end

      context "on update" do
        it_behaves_like "does not run extraction"
      end
    end

    context "for a wiki page" do
      let(:wiki_page) { create(:wiki_page) }
      let(:container) { wiki_page }

      context "on create" do
        it_behaves_like "does not run extraction"
      end

      context "on update" do
        it_behaves_like "does not run extraction"
      end
    end

    context "without a container" do
      let(:container) { nil }

      context "on create" do
        it_behaves_like "runs extraction"
      end

      context "on update" do
        it_behaves_like "does not run extraction"
      end
    end
  end

  describe "thumbnails" do
    describe "#thumbnailable?" do
      it "is true for a locally stored image" do
        expect(attachment.thumbnailable?).to be true
      end

      it "is false for a non-image" do
        allow(attachment).to receive(:is_image?).and_return(false)

        expect(attachment.thumbnailable?).to be false
      end

      it "is false when the feature is disabled", with_config: { attachments_thumbnails_enabled: false } do
        expect(attachment.thumbnailable?).to be false
      end

      it "is false for an externally stored attachment" do
        allow(attachment).to receive(:external_storage?).and_return(true)

        expect(attachment.thumbnailable?).to be false
      end
    end

    describe "paths" do
      before { allow(attachment).to receive(:id).and_return(123) }

      it "places thumbnails under the _thumbnails subtree keyed by id" do
        expected_dir = OpenProject::Configuration.attachments_storage_path.join("_thumbnails", "123")

        expect(attachment.thumbnails_directory.to_s).to eq expected_dir.to_s
        expect(attachment.thumbnail_path.to_s).to end_with "_thumbnails/123/card.webp"
      end
    end

    describe "#thumbnail_ready?" do
      it "reflects the thumbnail_status column" do
        attachment.thumbnail_status = "ready"
        expect(attachment.thumbnail_ready?).to be true

        attachment.thumbnail_status = "pending"
        expect(attachment.thumbnail_ready?).to be false
      end
    end

    describe "#thumbnail_available?" do
      it "is true for a thumbnailable image regardless of generation progress" do
        attachment.thumbnail_status = nil
        expect(attachment.thumbnail_available?).to be true

        attachment.thumbnail_status = "pending"
        expect(attachment.thumbnail_available?).to be true

        attachment.thumbnail_status = "ready"
        expect(attachment.thumbnail_available?).to be true
      end

      it "is false once generation is ruled out" do
        attachment.thumbnail_status = "unsupported"
        expect(attachment.thumbnail_available?).to be false

        attachment.thumbnail_status = "error"
        expect(attachment.thumbnail_available?).to be false
      end

      it "is false while a virus scan is pending" do
        allow(attachment).to receive(:pending_virus_scan?).and_return(true)

        expect(attachment.thumbnail_available?).to be false
      end

      it "is false for a non-thumbnailable attachment" do
        allow(attachment).to receive(:is_image?).and_return(false)

        expect(attachment.thumbnail_available?).to be false
      end
    end

    describe "#generate_thumbnail!" do
      let(:container) { work_package }
      let(:persisted_attachment) { create(:attachment, author:, container:, content_type: nil, file:) }
      let(:generator) { instance_double(Attachments::ThumbnailGenerator) }

      before do
        allow(Attachments::ThumbnailGenerator).to receive(:new).and_return(generator)
      end

      it "persists and returns a successful result" do
        allow(generator).to receive(:call).and_return(:ready)

        expect(persisted_attachment.generate_thumbnail!).to eq :ready
        expect(persisted_attachment.reload.thumbnail_status).to eq "ready"
      end

      it "persists and returns a failure result" do
        allow(generator).to receive(:call).and_return(:error)

        expect(persisted_attachment.generate_thumbnail!).to eq :error
        expect(persisted_attachment.reload.thumbnail_status).to eq "error"
      end
    end

    describe "thumbnail generation job on commit" do
      let(:container) { work_package }

      it "marks the attachment pending and enqueues the job for an image" do
        created = create(:attachment, author:, container:, content_type: nil, file:)

        expect(created.thumbnail_status).to eq "pending"
        expect(Attachments::GenerateThumbnailJob).to have_been_enqueued.with(created.id)
      end

      it "does not enqueue for a non-thumbnailable attachment" do
        allow_any_instance_of(described_class).to receive(:thumbnailable?).and_return(false) # rubocop:disable RSpec/AnyInstance

        created = create(:attachment, author:, container:, content_type: nil, file:)

        expect(created.thumbnail_status).to be_nil
        expect(Attachments::GenerateThumbnailJob).not_to have_been_enqueued
      end

      context "with virus scanning enabled",
              with_ee: %i[virus_scanning],
              with_settings: { antivirus_scan_mode: :clamav_socket } do
        it "defers generation until the scan completes" do
          created = create(:attachment, author:, container:, status: :uploaded, content_type: nil, file:)

          expect(created.pending_virus_scan?).to be true
          expect(created.thumbnail_status).to be_nil
          expect(Attachments::GenerateThumbnailJob).not_to have_been_enqueued
        end
      end
    end

    describe "removing thumbnails on destroy" do
      let(:container) { work_package }
      let(:persisted_attachment) { create(:attachment, author:, container:, content_type: nil, file:) }

      it "deletes the per-attachment thumbnail directory" do
        dir = persisted_attachment.thumbnails_directory
        FileUtils.mkdir_p(dir)
        FileUtils.touch(dir.join("card.webp"))

        persisted_attachment.destroy!

        expect(File.exist?(dir)).to be false
      end
    end

    describe ".generate_thumbnails_where_missing" do
      let(:container) { work_package }

      it "enqueues the job only for rows not yet considered or still pending" do
        ready = create(:attachment, author:, container:, content_type: nil, file:)
        ready.update_column(:thumbnail_status, "ready")
        pending = create(:attachment, author:, container:, content_type: nil, file: second_file)
        pending.update_column(:thumbnail_status, "pending")

        allow(Attachments::GenerateThumbnailJob).to receive(:perform_now)

        described_class.generate_thumbnails_where_missing(run_now: true)

        expect(Attachments::GenerateThumbnailJob).to have_received(:perform_now).with(pending.id)
        expect(Attachments::GenerateThumbnailJob).not_to have_received(:perform_now).with(ready.id)
      end
    end
  end
end
