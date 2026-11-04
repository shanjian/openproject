# frozen_string_literal: true

require "spec_helper"

RSpec.describe OpenProject::RemoveAsciiControlCharacters do
  subject(:call) { described_class.call(value) }

  context "with a clean string" do
    let(:value) { "Hello World" }

    it { is_expected.to eq("Hello World") }
  end

  context "with newline and tab characters" do
    let(:value) { "Hello\n\tWorld\r\n" }

    it { is_expected.to eq("HelloWorld") }
  end

  context "with null byte" do
    let(:value) { "Hello\x00World" }

    it { is_expected.to eq("HelloWorld") }
  end

  context "with escape and delete characters" do
    let(:value) { "Hello\x1B\x7FWorld" }

    it { is_expected.to eq("HelloWorld") }
  end

  context "with a mix of control characters" do
    let(:value) { "\x01He\x02llo\x03 \x04Wo\x05rld\x06" }

    it { is_expected.to eq("Hello World") }
  end

  context "with Unicode characters (preserved)" do
    let(:value) { "Héllo Wörld 日本語" }

    it { is_expected.to eq("Héllo Wörld 日本語") }
  end

  context "with spaces and quotes (preserved)" do
    let(:value) { %{It's a "test" value} }

    it { is_expected.to eq(%{It's a "test" value}) }
  end

  context "with a non-string value" do
    let(:value) { 42 }

    it { is_expected.to eq(42) }
  end

  context "with nil" do
    let(:value) { nil }

    it { is_expected.to be_nil }
  end
end
