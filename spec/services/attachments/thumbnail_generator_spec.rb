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

RSpec.describe Attachments::ThumbnailGenerator do
  shared_let(:author) { create(:user) }
  shared_let(:work_package) { create(:work_package) }

  let(:image_path) { Rails.root.join("spec/fixtures/files/image.png") }
  let(:attachment) do
    create(:attachment, author:, container: work_package, content_type: nil, file: File.open(image_path))
  end

  subject(:generator) { described_class.new(attachment) }

  after { FileUtils.rm_rf(attachment.thumbnails_directory) }

  describe "#call" do
    context "with a real raster image" do
      before do
        unless MiniMagick::Utilities.which("magick") || MiniMagick::Utilities.which("convert")
          skip "ImageMagick is not available in this environment"
        end
      end

      it "produces a WebP within the bounding box and returns :ready" do
        expect(generator.call).to eq :ready

        path = attachment.thumbnail_path
        expect(File.exist?(path)).to be true

        image = MiniMagick::Image.open(path.to_s)
        expect(image.type).to eq "WEBP"
        expect(image.width).to be <= described_class::BOUNDING_BOX
        expect(image.height).to be <= described_class::BOUNDING_BOX
      end
    end

    context "for a non-image attachment" do
      before { allow(attachment).to receive(:is_image?).and_return(false) }

      it "returns :unsupported without touching disk" do
        expect(generator.call).to eq :unsupported
        expect(File.exist?(attachment.thumbnail_path)).to be false
      end
    end

    context "when the source file cannot be read" do
      before { allow(attachment).to receive(:diskfile).and_return(nil) }

      it "returns :error" do
        expect(generator.call).to eq :error
      end
    end

    context "when the source exceeds the pixel budget" do
      before do
        oversized = instance_double(MiniMagick::Image, width: 100_000, height: 100_000)
        allow(MiniMagick::Image).to receive(:open).and_return(oversized)
      end

      it "returns :unsupported and writes no thumbnail" do
        expect(generator.call).to eq :unsupported
        expect(File.exist?(attachment.thumbnail_path)).to be false
      end
    end

    context "when ImageMagick conversion fails" do
      before do
        small = instance_double(MiniMagick::Image, width: 100, height: 100)
        allow(MiniMagick::Image).to receive(:open).and_return(small)
        tool = instance_double(MiniMagick::Tool)
        allow(tool).to receive(:merge!).and_return(tool)
        allow(tool).to receive(:call).and_raise(MiniMagick::Error, "boom")
        allow(MiniMagick).to receive(:convert).and_return(tool)
      end

      it "returns :error and leaves no partial file" do
        expect(generator.call).to eq :error
        expect(File.exist?(attachment.thumbnail_path)).to be false
      end
    end
  end
end
