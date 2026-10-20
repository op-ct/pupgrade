require 'json'

module Pupgrade
  module Surface
    # The differences between two surface documents: per surface kind, the
    # entries added and removed, and for an entry in both, each attribute
    # that differs, named by its path.
    module Diff
      SECTIONS = %w[classes defined_types functions type_aliases types providers facts].freeze
      KINDS    = %w[added removed changed].freeze

      # One difference.
      #
      # @!attribute [r] section
      #   @return [String] one of {SECTIONS}, or "module" for the module's own
      #     name and version
      # @!attribute [r] name
      #   @return [String] the entry
      # @!attribute [r] kind
      #   @return [String] one of {KINDS}
      # @!attribute [r] detail
      #   @return [String] what changed: the attribute path with its values
      Change = Data.define(:section, :name, :kind, :detail)

      # Longest rendering of a value in a detail.
      VALUE_WIDTH = 70

      module_function

      # @param from [Hash] a surface document
      # @param to [Hash] a surface document
      # @return [Array<Change>] module changes first, then by section and name
      def documents(from, to)
        changes = []
        %w[name version].each do |key|
          x = from.dig('module', key)
          y = to.dig('module', key)
          changes << Change.new(section: 'module', name: key, kind: 'changed', detail: "#{render(x)} -> #{render(y)}") if x != y
        end
        SECTIONS.each do |section|
          before = from[section] || {}
          after  = to[section] || {}
          (before.keys | after.keys).sort.each do |name|
            x = before[name]
            y = after[name]
            if x.nil?
              changes << Change.new(section: section, name: name, kind: 'added', detail: summary(y))
            elsif y.nil?
              changes << Change.new(section: section, name: name, kind: 'removed', detail: "was #{summary(x)}")
            else
              attribute_changes(x, y, []).each { |d| changes << Change.new(section: section, name: name, kind: 'changed', detail: d) }
            end
          end
        end
        changes
      end

      # Details for every attribute that differs between two entries: a key
      # in only one of them at the level it appears, else the leaf values.
      #
      # @return [Array<String>]
      def attribute_changes(x, y, path)
        if x.is_a?(Hash) && y.is_a?(Hash)
          (x.keys | y.keys).sort.flat_map do |key|
            here = path + [key]
            if !x.key?(key) then ["#{here.join('.')}: added #{render(y[key])}"]
            elsif !y.key?(key) then ["#{here.join('.')}: removed (was #{render(x[key])})"]
            else attribute_changes(x[key], y[key], here)
            end
          end
        elsif x != y
          ["#{path.join('.')}: #{render(x)} -> #{render(y)}"]
        else
          []
        end
      end

      # What an added or removed entry is, in a few words.
      def summary(entry)
        return render(entry) unless entry.is_a?(Hash)

        parts = []
        parts << entry['kind'] if entry['kind']
        parts << "#{entry['params'].size} params" if entry['params'].is_a?(Hash)
        parts << "#{entry['signatures'].size} signatures" if entry['signatures'].is_a?(Array)
        parts << "type #{entry['type']}" if entry['type'].is_a?(String) && entry['kind'].nil?
        parts << "in #{entry['file']}" if entry['file']
        parts.empty? ? render(entry) : parts.join(', ')
      end

      def render(value)
        text = value.is_a?(String) ? value : JSON.generate(value)
        (text.length > VALUE_WIDTH) ? "#{text[0, VALUE_WIDTH - 1]}…" : text
      end
    end
  end
end
