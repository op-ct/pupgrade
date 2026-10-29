require 'json'

module Pupgrade
  module Surface
    # The differences between two surface documents: the module's name and
    # version, what its metadata declares, and per surface kind the entries
    # added and removed, and for an entry in both, each attribute that
    # differs, named by its path.
    module Diff
      SECTIONS = %w[classes defined_types functions type_aliases types providers facts].freeze
      METADATA = %w[dependencies requirements operatingsystem_support].freeze
      KINDS    = %w[added removed changed].freeze

      # Every section a change can be in, in report order.
      ALL_SECTIONS = (%w[module metadata] + SECTIONS).freeze

      # One difference.
      #
      # @!attribute [r] section
      #   @return [String] one of {ALL_SECTIONS}
      # @!attribute [r] name
      #   @return [String] the entry: a class, a dependency, "version"
      # @!attribute [r] path
      #   @return [Array<String>] the attribute within the entry, empty for
      #     the entry itself; `["dependencies"]` for a metadata list
      # @!attribute [r] kind
      #   @return [String] one of {KINDS}; an attribute added or removed
      #     within an entry is a "changed" entry with `old` or `new` nil
      # @!attribute [r] old
      #   @return [Object, nil] the value before, nil when added
      # @!attribute [r] new
      #   @return [Object, nil] the value after, nil when removed
      Change = Data.define(:section, :name, :path, :kind, :old, :new) do
        # What changed, in one line: the attribute path with its values.
        def detail
          if path.empty? || section == 'metadata'
            return Diff.summary(new) if kind == 'added'
            return "was #{Diff.summary(old)}" if kind == 'removed'
          end
          head = path.empty? ? '' : "#{path.join('.')}: "
          if old.nil? then "#{head}added #{Diff.render(new)}"
          elsif new.nil? then "#{head}removed (was #{Diff.render(old)})"
          else "#{head}#{Diff.render(old)} -> #{Diff.render(new)}"
          end
        end

        # Whether a default changed only in its quotes: `'100'` became `100`,
        # or `"on"` became `'on'`. The text is the same once unquoted; the
        # type may not be (a String and an Integer).
        def requoted?
          path.last == 'default' && old.is_a?(String) && new.is_a?(String) && old != new &&
            Diff.unquoted(old) == Diff.unquoted(new)
        end
      end

      # A default's source text without the quotes of a string literal: a
      # single-quoted one, or a double-quoted one with nothing to interpolate.
      def self.unquoted(text)
        text[/\A'((?:[^'\\]|\\.)*)'\z/m, 1] || text[/\A"([^"\\$]*)"\z/, 1] || text
      end

      # Longest rendering of a value in a detail.
      VALUE_WIDTH = 70

      module_function

      # @param from [Hash] a surface document
      # @param to [Hash] a surface document
      # @return [Array<Change>] module changes first, then metadata, then by
      #   section and name
      def documents(from, to)
        changes = []
        %w[name version].each do |key|
          x = from.dig('module', key)
          y = to.dig('module', key)
          changes << Change.new(section: 'module', name: key, path: [], kind: 'changed', old: x, new: y) if x != y
        end
        METADATA.each do |list|
          before = from.dig('metadata', list) || {}
          after  = to.dig('metadata', list) || {}
          (before.keys | after.keys).sort.each do |name|
            x = before[name]
            y = after[name]
            next if before.key?(name) && after.key?(name) && x == y

            kind = if !before.key?(name) then 'added'
                   elsif !after.key?(name) then 'removed'
                   else 'changed'
                   end
            changes << Change.new(section: 'metadata', name: name, path: [list], kind: kind, old: x, new: y)
          end
        end
        SECTIONS.each do |section|
          before = from[section] || {}
          after  = to[section] || {}
          (before.keys | after.keys).sort.each do |name|
            x = before[name]
            y = after[name]
            if x.nil?
              changes << Change.new(section: section, name: name, path: [], kind: 'added', old: nil, new: y)
            elsif y.nil?
              changes << Change.new(section: section, name: name, path: [], kind: 'removed', old: x, new: nil)
            else
              attribute_changes(x, y, []).each do |path, a, b|
                changes << Change.new(section: section, name: name, path: path, kind: 'changed', old: a, new: b)
              end
            end
          end
        end
        changes
      end

      # Every attribute that differs between two entries: a key in only one
      # of them at the level it appears, else the leaf values.
      #
      # @return [Array<Array(Array<String>, Object, Object)>] path, old, new
      def attribute_changes(x, y, path)
        if x.is_a?(Hash) && y.is_a?(Hash)
          (x.keys | y.keys).sort.flat_map do |key|
            here = path + [key]
            if !x.key?(key) then [[here, nil, y[key]]]
            elsif !y.key?(key) then [[here, x[key], nil]]
            else attribute_changes(x[key], y[key], here)
            end
          end
        elsif x != y
          [[path, x, y]]
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
        parts << "type #{render(entry['type'])}" if entry['type'].is_a?(String) && entry['kind'].nil?
        parts << "in #{entry['file']}" if entry['file']
        parts.empty? ? render(entry) : parts.join(', ')
      end

      # A value on one line, cut at {VALUE_WIDTH}.
      def render(value)
        text = value.is_a?(String) ? value.gsub(/\s+/, ' ').strip : JSON.generate(value)
        (text.length > VALUE_WIDTH) ? "#{text[0, VALUE_WIDTH - 1]}…" : text
      end
    end
  end
end
