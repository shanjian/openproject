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

require "mini_magick"
require "fileutils"

module Attachments
  # Derives a small WebP thumbnail for a locally-stored image attachment using
  # ImageMagick (via mini_magick). The pipeline auto-orients (honoring EXIF),
  # strips metadata, resizes to fit within a bounding box without upscaling, and
  # re-encodes as WebP — so the served bytes are always a raster we produced,
  # never the user's original file verbatim.
  #
  # +#call+ never raises: it returns a status symbol the caller persists to
  # +Attachment#thumbnail_status+:
  #   :ready       — a valid thumbnail now exists on disk
  #   :unsupported — the source can't/shouldn't be thumbnailed (e.g. oversized)
  #   :error       — generation was attempted and failed (logged)
  #
  # See attachment_thumbnail_design.md §5.
  class ThumbnailGenerator
    # Bounding box (px) for the single "card" variant shipped in v1.
    BOUNDING_BOX = 240
    # WebP encoder quality.
    QUALITY = 75
    # Reject sources whose pixel count exceeds this before decoding, as a
    # decompression-bomb guard (complements ImageMagick's -limit area below).
    MAX_SOURCE_PIXELS = 64 * 1024 * 1024 # 64 megapixels
    # Hard ceiling on the time ImageMagick may spend per generation.
    GENERATION_TIMEOUT = 30 # seconds

    # Raised internally when a source is decodable but outside our budget; mapped
    # to a non-retryable :unsupported status.
    class OversizedSourceError < StandardError; end

    def initialize(attachment, variant: Attachment::DEFAULT_THUMBNAIL_VARIANT)
      @attachment = attachment
      @variant = variant
    end

    # @return [Symbol] :ready, :unsupported or :error
    def call
      return :unsupported unless @attachment.is_image?

      source = readable_source
      return :error if source.nil?

      generate(source)
      :ready
    rescue OversizedSourceError => e
      Rails.logger.info("Skipping thumbnail for attachment ##{@attachment.id}: #{e.message}")
      :unsupported
    rescue StandardError => e
      log_error(e)
      :error
    end

    private

    def readable_source
      path = @attachment.diskfile&.path
      return path if path && File.readable?(path)

      nil
    rescue StandardError => e
      log_error(e)
      nil
    end

    def generate(source)
      ensure_within_pixel_budget!(source)

      target = @attachment.thumbnail_path(variant: @variant)
      FileUtils.mkdir_p(target.dirname)

      # Write to a temp file in the same directory and rename into place so a
      # crashed/partial conversion can never be served as a valid thumbnail.
      tmp = target.dirname.join(".#{@variant}.#{Process.pid}.tmp.webp")
      begin
        convert(source, tmp.to_s)
        File.rename(tmp.to_s, target.to_s)
      ensure
        FileUtils.rm_f(tmp.to_s)
      end
    end

    # Cheap header read (identify) to reject decompression bombs before the full
    # decode performed by the resize step.
    def ensure_within_pixel_budget!(source)
      image = MiniMagick::Image.open(source)
      pixels = image.width.to_i * image.height.to_i

      if pixels.zero?
        raise OversizedSourceError, "could not read image geometry"
      elsif pixels > MAX_SOURCE_PIXELS
        raise OversizedSourceError, "source exceeds pixel budget (#{pixels} > #{MAX_SOURCE_PIXELS})"
      end
    end

    def convert(source, target)
      MiniMagick.convert.merge!(convert_arguments(source, target)).call
    end

    def convert_arguments(source, target)
      [
        # Resource guards, applied before the input is read.
        "-limit", "time", GENERATION_TIMEOUT.to_s,
        "-limit", "area", "256MB",
        "-limit", "memory", "256MB",
        "-limit", "disk", "1GB",
        # "[0]" takes only the first frame/page of animated or multi-page sources.
        "#{source}[0]",
        "-auto-orient",
        "-strip",
        # The trailing ">" resizes only when larger than the box (never upscale).
        "-resize", "#{BOUNDING_BOX}x#{BOUNDING_BOX}>",
        "-quality", QUALITY.to_s,
        # Force WebP output regardless of the temp file's extension.
        "webp:#{target}"
      ]
    end

    def log_error(error)
      Rails.logger.error(
        "Failed to generate thumbnail for attachment ##{@attachment.id}: #{error.message}"
      )
    end
  end
end
