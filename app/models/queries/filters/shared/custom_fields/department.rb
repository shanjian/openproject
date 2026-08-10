# frozen_string_literal: true

require_relative "base"

module Queries::Filters::Shared
  module CustomFields
    class Department < Base
      def ar_object_filter?
        true
      end

      def value_objects
        Group.organizational_units.where(id: @values)
      end

      def type
        :list_optional
      end

      protected

      def type_strategy_class
        ::Queries::Filters::Strategies::CfListOptional
      end
    end
  end
end
