require 'json'

module Pupgrade
  module Compile
    # The differences between two catalogs, or between two `compile` output
    # directories node by node: resources added and removed, parameters
    # added, removed, and changed, classes added and removed, and
    # relationship edges added and removed.
    module CatalogDiff
      KINDS = %w[node-missing resource-added resource-removed param-added param-removed param-changed
                 class-added class-removed edge-added edge-removed].freeze

      # Longest rendering of a parameter value in a detail.
      VALUE_WIDTH = 60

      # Characters kept either side of the differing stretch of a long string.
      CONTEXT = 12

      # One difference.
      #
      # @!attribute [r] certname
      #   @return [String]
      # @!attribute [r] kind
      #   @return [String] one of {KINDS}
      # @!attribute [r] resource
      #   @return [String, nil] "Type[title]"; a class name for a class
      #     change; "source -> target" for an edge; nil for a node change
      # @!attribute [r] param
      #   @return [String, nil] the parameter, for a param change
      # @!attribute [r] detail
      #   @return [String] what it was and what it is
      Change = Data.define(:certname, :kind, :resource, :param, :detail)

      class Error < StandardError; end

      CATALOG_FILE = 'catalog.json'.freeze

      module_function

      # The changes between two `compile` output directories, every node in
      # either: a node in only one of them is a `node-missing` change.
      #
      # @param from_dir [String]
      # @param to_dir [String]
      # @param ignore_params [Array<String>] parameters never compared
      # @return [Array<Change>] by certname, then as {catalogs} orders them
      # @raise [Error] when a directory or a catalog cannot be read
      def directories(from_dir, to_dir, ignore_params: [])
        before = catalogs_in(from_dir)
        after  = catalogs_in(to_dir)
        (before.keys | after.keys).sort.flat_map do |certname|
          if before[certname].nil?
            [Change.new(certname: certname, kind: 'node-missing', resource: nil, param: nil, detail: "only in #{to_dir}")]
          elsif after[certname].nil?
            [Change.new(certname: certname, kind: 'node-missing', resource: nil, param: nil, detail: "only in #{from_dir}")]
          else
            catalogs(read(before[certname]), read(after[certname]), certname: certname, ignore_params: ignore_params)
          end
        end
      end

      # @return [Hash{String => String}] certname to catalog path
      def catalogs_in(dir)
        raise Error, "#{dir}: no such directory" unless File.directory?(dir)

        if File.file?(File.join(dir, CATALOG_FILE))
          { File.basename(dir) => File.join(dir, CATALOG_FILE) }
        else
          Dir.children(dir).sort.filter_map { |name|
            path = File.join(dir, name, CATALOG_FILE)
            [name, path] if File.file?(path)
          }.to_h
        end
      end

      # @return [Hash] a catalog document
      # @raise [Error] when the file does not read as one
      def read(path)
        data = JSON.parse(File.read(path))
        raise Error, "#{path}: not a catalog (no resources list)" unless data.is_a?(Hash) && data['resources'].is_a?(Array)

        data
      rescue JSON::ParserError => e
        raise Error, "#{path}: #{e.message}"
      end

      # The changes between two catalog documents: classes, then resources
      # by name, then edges.
      #
      # @param from [Hash]
      # @param to [Hash]
      # @return [Array<Change>]
      def catalogs(from, to, certname:, ignore_params: [])
        changes = []
        before_classes = Array(from['classes']).map(&:to_s)
        after_classes  = Array(to['classes']).map(&:to_s)
        (after_classes - before_classes).sort.each { |c| changes << Change.new(certname: certname, kind: 'class-added', resource: c, param: nil, detail: 'class') }
        (before_classes - after_classes).sort.each { |c| changes << Change.new(certname: certname, kind: 'class-removed', resource: c, param: nil, detail: 'class') }

        before = from['resources'].to_h { |r| [key(r), r] }
        after  = to['resources'].to_h { |r| [key(r), r] }
        (before.keys | after.keys).sort.each do |name|
          x = before[name]
          y = after[name]
          if x.nil?
            changes << Change.new(certname: certname, kind: 'resource-added', resource: name, param: nil, detail: where(y))
          elsif y.nil?
            changes << Change.new(certname: certname, kind: 'resource-removed', resource: name, param: nil, detail: "was #{where(x)}")
          else
            changes.concat(params(certname, name, x['parameters'] || {}, y['parameters'] || {}, ignore_params))
          end
        end

        before_edges = Array(from['edges']).map { |e| "#{e['source']} -> #{e['target']}" }
        after_edges  = Array(to['edges']).map { |e| "#{e['source']} -> #{e['target']}" }
        (after_edges - before_edges).sort.each { |e| changes << Change.new(certname: certname, kind: 'edge-added', resource: e, param: nil, detail: 'relationship') }
        (before_edges - after_edges).sort.each { |e| changes << Change.new(certname: certname, kind: 'edge-removed', resource: e, param: nil, detail: 'relationship') }
        changes
      end

      def params(certname, name, before, after, ignore)
        (before.keys | after.keys).sort.filter_map do |param|
          next if ignore.include?(param)

          x = before[param]
          y = after[param]
          if !before.key?(param)
            Change.new(certname: certname, kind: 'param-added', resource: name, param: param, detail: render(y))
          elsif !after.key?(param)
            Change.new(certname: certname, kind: 'param-removed', resource: name, param: param, detail: "was #{render(x)}")
          elsif x != y
            Change.new(certname: certname, kind: 'param-changed', resource: name, param: param, detail: changed(x, y))
          end
        end
      end

      def key(resource)
        "#{resource['type']}[#{resource['title']}]"
      end

      # Where a resource is declared, else how many parameters it carries.
      def where(resource)
        return "#{resource['file']}:#{resource['line']}" if resource['file']

        "#{(resource['parameters'] || {}).size} params"
      end

      # Two values side by side. Long strings are cut to the stretch that
      # differs, with some of what surrounds it, so the change shows.
      def changed(x, y)
        return "#{render(x)} -> #{render(y)}" unless x.is_a?(String) && y.is_a?(String) && [x, y].any? { |v| v.length > VALUE_WIDTH }

        prefix = 0
        prefix += 1 while prefix < x.length && prefix < y.length && x[prefix] == y[prefix]
        suffix = 0
        suffix += 1 while suffix < x.length - prefix && suffix < y.length - prefix && x[-1 - suffix] == y[-1 - suffix]
        "#{render(excerpt(x, prefix, suffix))} -> #{render(excerpt(y, prefix, suffix))}"
      end

      # The part of `value` between a common prefix and suffix, with up to
      # {CONTEXT} characters of each kept, and an ellipsis where it is cut.
      def excerpt(value, prefix, suffix, context = CONTEXT)
        from = [prefix - context, 0].max
        to   = [value.length - suffix + context, value.length].min
        "#{'…' if from.positive?}#{value[from...to]}#{'…' if to < value.length}"
      end

      # A value as compact JSON, cut to {VALUE_WIDTH}.
      def render(value)
        text = value.is_a?(String) ? value.inspect : JSON.generate(value)
        (text.length > VALUE_WIDTH) ? "#{text[0, VALUE_WIDTH - 1]}…" : text
      end
    end
  end
end
