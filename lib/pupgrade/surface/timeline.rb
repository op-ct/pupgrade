require 'pupgrade/surface/diff'
require 'pupgrade/surface/render'

module Pupgrade
  module Surface
    # How surface items read across a sequence of documents, oldest first:
    # the item's text where it first appears, "changed: ..." where it
    # differs from the document before, "=" where it does not, and
    # "absent" where the document lacks it.
    class Timeline
      # One entry of a surface, or one parameter of a class or defined type.
      #
      # @!attribute [r] section
      #   @return [String] one of {Diff::SECTIONS}
      # @!attribute [r] name
      #   @return [String] the entry
      # @!attribute [r] param
      #   @return [String, nil] the parameter; nil for the entry itself
      Item = Data.define(:section, :name, :param) do
        # @return [String] "function stdlib::shout", "param apache::version"
        def heading
          param ? "param #{name}::#{param}" : "#{Render::SINGULAR.fetch(section)} #{name}"
        end

        # @return [String] what a glob matches: the name, or name::param
        def key
          param ? "#{name}::#{param}" : name
        end
      end

      # Sections whose entries have parameters an item can name.
      PARAMETERIZED = %w[classes defined_types].freeze

      # @param docs [Array<Hash>] surface documents, oldest first
      def initialize(docs)
        @docs = docs
      end

      # Every entry in any document, and every parameter of a class or
      # defined type, whose key matches a glob (case-insensitive), in
      # section order then by key.
      #
      # @param globs [Array<String>]
      # @return [Array<Item>]
      def items(globs)
        found = @docs.flat_map do |doc|
          Diff::SECTIONS.flat_map do |section|
            doc.fetch(section, {}).flat_map do |name, entry|
              params = (PARAMETERIZED.include?(section) && entry.is_a?(Hash)) ? (entry['params'] || {}).keys : []
              [Item.new(section: section, name: name, param: nil)] + params.map { |p| Item.new(section: section, name: name, param: p) }
            end
          end
        end
        found.uniq.select { |item| globs.any? { |g| File.fnmatch?(g, item.key, File::FNM_CASEFOLD) } }
          .sort_by { |item| [Diff::SECTIONS.index(item.section), item.key.downcase] }
      end

      # @param item [Item]
      # @return [Array<String>] one cell per document
      def cells(item)
        previous = nil
        @docs.map.with_index do |doc, i|
          entry = entry_in(doc, item)
          cell =
            if entry.nil? then 'absent'
            elsif i.zero? || previous.nil? then text(item, entry)
            elsif entry == previous then '='
            else "changed: #{text(item, entry)}"
            end
          previous = entry
          cell
        end
      end

      private

      def entry_in(doc, item)
        entry = doc.dig(item.section, item.name)
        return entry unless item.param

        entry.is_a?(Hash) ? entry.dig('params', item.param) : nil
      end

      def text(item, entry)
        item.param ? Render.abbreviate(Render.declaration(item.param, entry)) : Render.abbreviate(Render.entry_text(item.section, entry))
      end
    end
  end
end
