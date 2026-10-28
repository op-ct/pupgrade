require 'json'
require 'yaml'

module Pupgrade
  module Compile
    # One node's facts to compile with, read from a factset file in either
    # layout: onceover's (`name`, `values`, optional `trusted` and
    # `trusted_external`) or driftless's export (the facts hash alone).
    #
    # @!attribute [r] certname
    #   @return [String] onceover's `name` or `trusted.certname`, else the
    #     facts' `trusted.certname` or `clientcert`, else the file name
    # @!attribute [r] values
    #   @return [Hash] the facts
    # @!attribute [r] trusted
    #   @return [Hash, nil] `$trusted` as given; nil to synthesise one
    # @!attribute [r] trusted_external
    #   @return [Hash] `$trusted['external']`
    # @!attribute [r] path
    #   @return [String] the file it came from
    Factset = Data.define(:certname, :values, :trusted, :trusted_external, :path)

    class Factset
      class Error < StandardError; end

      EXTENSIONS = %w[.json .yaml .yml].freeze

      # Every factset under the paths: a file, or every factset file under
      # a directory (an onceover role tree included), sorted by path.
      #
      # @param paths [Array<String>]
      # @return [Array<Factset>]
      # @raise [Error] on a path that is not there or a file that does not read
      def self.load_all(paths)
        Array(paths).flat_map do |path|
          path = File.expand_path(path)
          if File.directory?(path)
            Dir.glob(File.join(path, '**', '*')).select { |f| File.file?(f) && EXTENSIONS.include?(File.extname(f)) }.sort.map { |f| load(f) }
          elsif File.file?(path)
            [load(path)]
          else
            raise Error, "#{path}: no such file or directory"
          end
        end
      end

      # @param path [String]
      # @return [Factset]
      # @raise [Error] when the file does not parse or holds no facts hash
      def self.load(path)
        data = parse(path)
        raise Error, "#{path}: expected a mapping, got #{data.class}" unless data.is_a?(Hash)

        if data['values'].is_a?(Hash)
          values = data['values']
          name   = data['name'] || data.dig('trusted', 'certname')
        else
          values = data
          name   = nil
        end
        name ||= certname_in(values) || File.basename(path, File.extname(path))
        new(certname: name.to_s, values: values, trusted: data['values'].is_a?(Hash) ? data['trusted'] : nil,
            trusted_external: (data['values'].is_a?(Hash) && data['trusted_external']) || {}, path: path)
      end

      # The certname the facts report: the verified one in a `trusted`
      # fact, else the node's own `clientcert`.
      #
      # @return [String, nil]
      def self.certname_in(values)
        trusted = values['trusted']
        (trusted.is_a?(Hash) && trusted['certname']) || values['clientcert']
      end

      def self.parse(path)
        text = File.read(path)
        (File.extname(path) == '.json') ? JSON.parse(text) : YAML.safe_load(text, aliases: true, filename: path)
      rescue JSON::ParserError, Psych::SyntaxError => e
        raise Error, "#{path}: #{e.message}"
      end
    end
  end
end
