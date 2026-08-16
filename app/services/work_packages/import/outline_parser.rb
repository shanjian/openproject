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

module WorkPackages
  module Import
    class OutlineParser
      Node = Struct.new(:level, :type_name, :subject, :attributes, :description,
                        :source_line, :parent_index)
      Document = Struct.new(:front_matter, :nodes)

      class ParseError < StandardError
        attr_reader :source_line

        def initialize(message, source_line)
          super(message)
          @source_line = source_line
        end
      end

      HEADING = /\A(#+)\s+(.+)\z/
      BULLET = /\A-\s+([^:]+):\s*(.*)\z/

      # Subjects are plain text in OpenProject, so inline markdown in a heading
      # (`**bold**`, `*italic*`, `` `code` ``, "\$"-style escapes) must not survive
      # into the subject. Underscore emphasis is only stripped at word boundaries:
      # intra-word underscores (snake_case identifiers) are not emphasis in markdown.
      # Backslash-escaped markers ("\*foo\*") are not emphasis either -- the (?<!\\)
      # guards keep them for the escape pass below, which unescapes them to literals.
      # Descriptions stay untouched -- they are rendered as markdown.
      INLINE_MARKDOWN = [
        [/(?<!\\)(\*{1,3})(?=\S)(.+?)(?<=\S)(?<!\\)\1/, '\2'],
        [/(?<![[:alnum:]_\\])(_{1,3})(?=\S)(.+?)(?<=\S)(?<!\\)\1(?![[:alnum:]_])/, '\2'],
        [/(?<!\\)`([^`]+?)(?<!\\)`/, '\1']
      ].freeze
      ESCAPED_PUNCTUATION = /\\([[:punct:]])/

      def self.call(markdown)
        new(markdown).call
      end

      def initialize(markdown)
        @lines = markdown.to_s.split("\n")
      end

      def call
        front_matter, index = parse_front_matter(0)
        nodes = parse_nodes(index)
        apply_inheritance(nodes, front_matter)
        ServiceResult.success(result: Document.new(front_matter:, nodes:))
      rescue ParseError => e
        ServiceResult.failure(errors: [{ source_line: e.source_line, message: e.message }])
      end

      private

      def parse_front_matter(index) # rubocop:disable Metrics/AbcSize,Metrics/PerceivedComplexity
        return [{}, index] unless @lines[index]&.strip == "---"

        front_matter = {}
        cursor = index + 1

        while cursor < @lines.length && @lines[cursor].strip != "---"
          line = @lines[cursor]
          unless line.strip.empty?
            raise ParseError.new("malformed front matter line", cursor + 1) unless line.include?(":")

            key, _sep, value = line.partition(":")
            key = key.strip
            raise ParseError.new("duplicate front matter key #{key.inspect}", cursor + 1) if front_matter.key?(key)

            front_matter[key] = value.strip
          end
          cursor += 1
        end

        raise ParseError.new("unterminated front matter", index + 1) if cursor >= @lines.length

        [front_matter, cursor + 1]
      end

      def parse_nodes(start_index) # rubocop:disable Metrics/AbcSize,Metrics/PerceivedComplexity
        nodes = []
        stack = []
        root_depth = nil
        index = start_index

        while index < @lines.length
          line = @lines[index]

          if (match = HEADING.match(line))
            level = match[1].length
            type_name, _sep, subject = match[2].partition(":")
            root_depth ||= level
            raise ParseError.new("heading depth is shallower than the document root", index + 1) if level < root_depth

            stack.pop while stack.any? && stack.last[:level] >= level

            if stack.empty?
              raise ParseError.new("heading depth skips a level", index + 1) if level != root_depth

              parent_index = nil
            else
              raise ParseError.new("heading depth skips a level", index + 1) if level != stack.last[:level] + 1

              parent_index = stack.last[:index]
            end

            node = Node.new(level:, type_name: type_name.strip, subject: strip_inline_markdown(subject.strip),
                            attributes: {}, description: "", source_line: index + 1, parent_index:)
            nodes << node
            stack.push(level:, index: nodes.length - 1)

            index = parse_bullets(node, index + 1)
            index = parse_description(node, index)
          elsif line.strip.empty?
            index += 1
          elsif BULLET.match?(line)
            raise ParseError.new("attribute bullet before any heading", index + 1)
          else
            raise ParseError.new("unexpected content before any heading", index + 1)
          end
        end

        nodes
      end

      def parse_bullets(node, index)
        while index < @lines.length && (match = BULLET.match(@lines[index]))
          key = match[1].strip
          raise ParseError.new("duplicate attribute key #{key.inspect}", index + 1) if node.attributes.key?(key)

          node.attributes[key] = match[2].strip
          index += 1
        end

        index
      end

      def parse_description(node, index)
        description_lines = []
        while index < @lines.length && !HEADING.match?(@lines[index])
          description_lines << @lines[index]
          index += 1
        end
        node.description = description_lines.join("\n").strip

        index
      end

      def strip_inline_markdown(text)
        result = text
        loop do
          stripped = INLINE_MARKDOWN.reduce(result) { |acc, (pattern, replacement)| acc.gsub(pattern, replacement) }
          break if stripped == result

          result = stripped
        end
        result.gsub(ESCAPED_PUNCTUATION, '\1')
      end

      def apply_inheritance(nodes, front_matter)
        inheritable_front_matter = front_matter.except("Project")

        nodes.each do |node|
          inherited = ancestors_root_first(nodes, node)
                        .reduce(inheritable_front_matter) { |acc, ancestor| acc.merge(ancestor.attributes) }
          node.attributes = inherited.merge(node.attributes)
        end
      end

      def ancestors_root_first(nodes, node)
        chain = []
        current = node
        chain << (current = nodes[current.parent_index]) while current.parent_index
        chain.reverse
      end
    end
  end
end
