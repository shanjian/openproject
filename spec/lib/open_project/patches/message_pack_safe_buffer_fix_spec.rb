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

# Rails registers ActiveSupport::SafeBuffer as MessagePack ext type 18 with
# unpacker: :new. MessagePack ext payloads are raw bytes (BINARY), so the default
# unpacker reconstructs SafeBuffer with ASCII-8BIT encoding, even when the
# original was UTF-8. This patch overrides the unpacker to force UTF-8.
RSpec.describe OpenProject::Patches::MessagePackSafeBufferFix do
  # Use the same serializer the cache store uses to cover the real path.
  let(:serializer) { ActiveSupport::MessagePack::CacheSerializer }
  let(:html) { "<p>Héllo &amp; wörld — «quoted»</p>" }

  def round_trip(value)
    serializer.load(serializer.dump(value))
  end

  shared_examples "a correctly round-tripped SafeBuffer", :aggregate_failures do
    it "returns a utf-8 SafeBuffer, preserving the original content and html safety" do
      expect(round_trip(subject)).to be_a(ActiveSupport::SafeBuffer)
      expect(round_trip(subject).to_s).to eq(subject.to_s.dup.force_encoding(Encoding::UTF_8))
      expect(round_trip(subject).encoding).to eq(Encoding::UTF_8)
      expect(round_trip(subject)).to be_html_safe
    end
  end

  context "with a UTF-8 SafeBuffer (normal render output)" do
    subject { ActiveSupport::SafeBuffer.new(html) }

    include_examples "a correctly round-tripped SafeBuffer"
  end

  context "with a BINARY-encoded SafeBuffer (e.g. content assembled from binary bytes)" do
    subject { ActiveSupport::SafeBuffer.new(html.b) }

    it "has BINARY encoding before round-trip (confirms precondition)" do
      expect(subject.encoding).to eq(Encoding::BINARY)
    end

    include_examples "a correctly round-tripped SafeBuffer"
  end
end
