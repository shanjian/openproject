# frozen_string_literal: true

# -- copyright
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
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA.
#
# See COPYRIGHT and LICENSE files for more details.
# ++

require "spec_helper"

RSpec.describe McpOutputFilters::HashFilter do
  # records every hash it is handed, and stops descending wherever it is told to
  let(:recording_filter) do
    Class.new(described_class) do
      attr_reader :seen

      def initialize(stop_at: nil)
        super()
        @seen = []
        @stop_at = stop_at
      end

      private

      def on_hash(hash) # rubocop:disable Naming/PredicateMethod
        @seen << hash.dup
        @stop_at.nil? || !hash.key?(@stop_at)
      end
    end
  end

  describe "#filter" do
    it "visits every hash reachable through hash values and array elements" do
      filter = recording_filter.new
      filter.filter({ "a" => { "b" => 1 }, "c" => [{ "d" => 2 }, [{ "e" => 3 }]] })

      expect(filter.seen).to contain_exactly(
        { "a" => { "b" => 1 }, "c" => [{ "d" => 2 }, [{ "e" => 3 }]] },
        { "b" => 1 }, { "d" => 2 }, { "e" => 3 }
      )
    end

    it "stops descending where #on_hash returns false" do
      filter = recording_filter.new(stop_at: "stop")
      filter.filter({ "stop" => true, "child" => { "buried" => true } })

      expect(filter.seen).to contain_exactly({ "stop" => true, "child" => { "buried" => true } })
    end

    it "ignores scalars" do
      filter = recording_filter.new
      filter.filter("a string")

      expect(filter.seen).to be_empty
    end

    # McpTools::Base#format_response threads the return value through its chain of filters, so a
    # filter that returned nil here would blank out the whole response body.
    it "returns the structure it was given, even when the descent stops at the top level" do
      filter = recording_filter.new(stop_at: "stop")
      payload = { "stop" => true }

      expect(filter.filter(payload)).to be(payload)
    end
  end

  describe "#on_hash" do
    it "is the subclass's responsibility" do
      expect { described_class.new.filter({ "a" => 1 }) }.to raise_error(NotImplementedError)
    end
  end
end
