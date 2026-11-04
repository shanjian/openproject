# frozen_string_literal: true

module OpenProject
  # Strips ASCII control characters (0x00–0x1F, 0x7F) from a string.
  # Designed for use with ActiveRecord's `normalizes` API:
  #
  #   normalizes :name, with: OpenProject::RemoveAsciiControlCharacters
  #
  RemoveAsciiControlCharacters = ->(value) { value.is_a?(String) ? value.gsub(/[\x00-\x1F\x7F]/, "") : value }
end
