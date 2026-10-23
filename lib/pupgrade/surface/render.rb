require 'json'
require 'semantic_puppet'

require 'pupgrade/surface/diff'

module Pupgrade
  module Surface
    # How a {Diff::Change} reads: the item it is about, the difference as a
    # phrase, and the values abbreviated to one line, or in full as a block.
    module Render
      SINGULAR = {
        'module'        => 'module',
        'classes'       => 'class',
        'defined_types' => 'defined type',
        'functions'     => 'function',
        'type_aliases'  => 'type alias',
        'types'         => 'type',
        'providers'     => 'provider',
        'facts'         => 'fact',
      }.freeze

      METADATA = {
        'dependencies'            => 'dependency',
        'requirements'            => 'requirement',
        'operatingsystem_support' => 'OS',
      }.freeze

      # Attribute names as the phrases call them.
      ATTRIBUTES = {
        'return_type'   => 'return type',
        'captures_rest' => 'splat',
        'type'          => 'type',
      }.freeze

      # Data types whose bracketed part can run to any length, so it folds
      # to `[…]`; a bounded one (`Integer[0, 65535]`, `String[1]`) is short
      # and its bounds are what changes, so it stays whole.
      UNBOUNDED = %w[Variant Enum Pattern Tuple Struct Regexp Error Hash Array].freeze

      # Longest value in a one-line detail.
      WIDTH = 70

      # Marks telling two collapsed values apart when they read alike.
      SUPERSCRIPTS = %w[¹ ²].freeze

      module_function

      # @param change [Diff::Change]
      # @return [String] "defined type puppet_authorization::rule::allow"
      def item(change)
        kind, namespace, leaf = item_parts(change)
        "#{kind} #{namespace}#{leaf}"
      end

      # The item in three parts for colouring: the surface kind, the
      # namespace (`mod::class::` for a parameter, `mod::` for a namespaced
      # name, '' when there is none), and the leaf.
      #
      # @return [Array(String, String, String)]
      def item_parts(change)
        case change.section
        when 'module'   then ['module', '', change.name]
        when 'metadata' then [METADATA.fetch(change.path.first), '', change.name]
        else
          kind = SINGULAR.fetch(change.section)
          if change.path.first == 'params' && change.path.size >= 2
            param = change.path[1]
            %w[classes defined_types].include?(change.section) ? [kind, "#{change.name}::", param] : [kind, "#{change.name} ", param]
          elsif change.name.include?('::')
            head, _, tail = change.name.rpartition('::')
            [kind, "#{head}::", tail]
          else
            [kind, '', change.name]
          end
        end
      end

      # @return [String] "changed major release", "added required param",
      #   "changed param type", "removed"
      def difference(change)
        if change.section == 'module'
          return 'renamed' if change.name == 'name'

          level = release_level(change.old, change.new)
          return level ? "changed #{level} release" : 'changed version'
        end
        return change.kind if change.path.empty? || change.section == 'metadata'

        path = change.path
        if path.first == 'params'
          return 'added required param' if path.size == 2 && change.old.nil? && required?(change.new)
          return "#{change.old.nil? ? 'added' : 'removed'} param" if path.size == 2

          attribute = path[2..].map { |a| ATTRIBUTES.fetch(a, a.tr('_', ' ')) }.join(' ')
          return "added param #{attribute}" if change.old.nil?
          return "removed param #{attribute}" if change.new.nil?

          return "changed param #{attribute}"
        end
        attribute = path.map { |a| ATTRIBUTES.fetch(a, a.tr('_', ' ')) }.join(' ')
        return "added #{attribute}" if change.old.nil?
        return "removed #{attribute}" if change.new.nil?

        "changed #{attribute}"
      end

      # @return [String] the values on one line: "old -> new" abbreviated,
      #   a parameter as its declaration, signatures as parameter lists, or
      #   what an added or removed entry is; two sides that read alike once
      #   folded are told apart as `[…¹] -> […²]`
      def detail(change)
        return abbreviate(summary(change, change.new)) if entry_added?(change)
        return "was #{abbreviate(summary(change, change.old))}" if entry_removed?(change)
        return abbreviate(text_of(change, change.new)) if change.old.nil?
        return "was #{abbreviate(text_of(change, change.old))}" if change.new.nil?

        old = abbreviate(text_of(change, change.old))
        new = abbreviate(text_of(change, change.new))
        old, new = distinguish(old, new) if old == new
        "#{old} -> #{new}"
      end

      # A value as it reads in a detail: a parameter as `Type $name =
      # default`, signatures as `(a, b)`, anything else as its text.
      def text_of(change, v)
        path = change.path
        if path.first == 'params' && path.size == 2 && v.is_a?(Hash)
          declaration(path[1], v)
        elsif path == ['signatures'] && v.is_a?(Array)
          v.map { |sig| signature(sig) }.join(' | ')
        else
          value(v)
        end
      end

      # @return [String] "Boolean $x = $is_slave"
      def declaration(name, param)
        parts = [param['type'], "#{'*' if param['captures_rest']}$#{name}"].compact
        parts << "= #{param['default']}" if param.key?('default')
        parts.join(' ')
      end

      # @return [String] "(text, times) -> String"
      def signature(sig)
        text = "(#{Array(sig['params']).join(', ')}#{", &#{sig['block']}" if sig['block']})"
        text += " -> #{sig['return_type']}" if sig['return_type']
        text
      end

      # What an added or removed entry is: a metadata value as written, a
      # surface entry in a few words.
      def summary(change, entry)
        (change.section == 'metadata') ? value(entry) : Diff.summary(entry)
      end

      # The change as lines for a block layout: its heading, then the old
      # and new values in full, each line of a value on a line of its own.
      #
      # @return [Array<String>]
      def block(change)
        lines = ["#{item(change)}: #{difference(change)}"]
        if entry_added?(change) || entry_removed?(change)
          lines << "  #{entry_added?(change) ? '+' : '-'} #{summary(change, entry_added?(change) ? change.new : change.old)}"
        else
          lines.concat(text_of(change, change.old).lines.map.with_index { |l, i| "  #{i.zero? ? '-' : ' '} #{l.chomp}" }) unless change.old.nil?
          lines.concat(text_of(change, change.new).lines.map.with_index { |l, i| "  #{i.zero? ? '+' : ' '} #{l.chomp}" }) unless change.new.nil?
        end
        lines
      end

      # @return [String] the text with its whitespace collapsed and the
      #   bracketed part of every unbounded type reduced to `[…]`, with
      #   `Optional[X]` showing X by the same rule; cut at {WIDTH}
      def abbreviate(text)
        text = text.to_s.gsub(/\s+/, ' ').strip
        text = fold_brackets(text)
        (text.length > WIDTH) ? "#{text[0, WIDTH - 1]}…" : text
      end

      def fold_brackets(text)
        out = +''
        i = 0
        while i < text.length
          open = text.index('[', i)
          if open.nil?
            out << text[i..]
            break
          end
          close = matching_bracket(text, open)
          if close.nil?
            out << text[i..]
            break
          end
          out << text[i...open]
          name  = out[/[A-Za-z_:]+\z/]
          inner = text[open + 1...close]
          out << if name.nil? || UNBOUNDED.include?(name.split('::').last) then '[…]'
                 else "[#{fold_brackets(inner)}]"
                 end
          i = close + 1
        end
        out
      end

      def matching_bracket(text, open)
        depth = 0
        (open...text.length).each do |j|
          depth += 1 if text[j] == '['
          depth -= 1 if text[j] == ']'
          return j if depth.zero?
        end
        nil
      end

      # Two abbreviated values that read the same: each ellipsis carries a
      # superscript so the reader knows they differ inside.
      def distinguish(old, new)
        [old.gsub('…', "…#{SUPERSCRIPTS[0]}"), new.gsub('…', "…#{SUPERSCRIPTS[1]}")]
      end

      # @return [String, nil] "major", "minor", or "patch"
      def release_level(from, to)
        a = parse(from)
        b = parse(to)
        return nil unless a && b

        if a.major != b.major then 'major'
        elsif a.minor != b.minor then 'minor'
        else 'patch'
        end
      end

      def parse(version)
        SemanticPuppet::Version.parse(version.to_s.sub(/\Av/, ''))
      rescue SemanticPuppet::Version::ValidationFailure
        nil
      end

      def required?(param)
        param.is_a?(Hash) && !param.key?('default') && !param['captures_rest']
      end

      def entry_added?(change)
        change.kind == 'added' && (change.path.empty? || change.section == 'metadata')
      end

      def entry_removed?(change)
        change.kind == 'removed' && (change.path.empty? || change.section == 'metadata')
      end

      # A value as text: a list of scalars (OS releases) joined, anything
      # else structured as JSON.
      def value(v)
        return v if v.is_a?(String)
        return v.map(&:to_s).join(', ') if v.is_a?(Array) && v.all? { |x| x.is_a?(String) || x.is_a?(Numeric) }

        JSON.generate(v)
      end
    end
  end
end
