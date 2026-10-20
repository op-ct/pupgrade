require 'yaml'

module Pupgrade
  module Compile
    # What the execution guard answers with, read from a site's stub file:
    #
    #     ---
    #     commands:
    #       - match: '^iptables-save'   # a regexp against the command line
    #         stdout: ''                # the output to return (default '')
    #       - match: '^systemctl '
    #         action: allow             # run it for real, and record it
    #     facts:                        # Facter.value reads the factset lacks
    #       fips_enabled: false
    #
    # A command no entry matches gets the run's `on_leak` policy: `raise`
    # stops the node's compile, `allow` runs it and records it.
    class Stubs
      class Error < StandardError; end

      ACTIONS = %w[stub allow].freeze

      # One `commands` entry.
      #
      # @!attribute [r] match
      #   @return [Regexp]
      # @!attribute [r] action
      #   @return [String] "stub" or "allow"
      # @!attribute [r] stdout
      #   @return [String] what a stubbed command prints
      Command = Data.define(:match, :action, :stdout)

      # @param path [String]
      # @return [Stubs]
      # @raise [Error] when the file does not read as a stub file
      def self.load(path)
        data = YAML.safe_load(File.read(path), aliases: true, filename: path) || {}
        raise Error, "#{path}: expected a mapping, got #{data.class}" unless data.is_a?(Hash)

        new(data, path: path)
      rescue Errno::ENOENT
        raise Error, "#{path}: no such file"
      rescue Psych::SyntaxError => e
        raise Error, "#{path}: #{e.message}"
      end

      # @return [Stubs] answering nothing
      def self.empty
        new({}, path: nil)
      end

      attr_reader :path, :commands, :facts

      # @param data [Hash] the parsed stub file
      def initialize(data, path:)
        @path     = path
        @commands = Array(data['commands']).map { |c| command(c) }
        @facts    = (data['facts'] || {}).to_h { |k, v| [k.to_s, v] }
      end

      # @param command_line [String]
      # @return [Command, nil] the first entry matching the command line
      def for_command(command_line)
        @commands.find { |c| c.match.match?(command_line) }
      end

      # @param name [String] a fact, dotted for a path into a structured one
      # @return [Array(Boolean, Object)] whether the stubs answer, and with what
      def fact(name)
        return [true, @facts[name]] if @facts.key?(name)

        head, rest = name.split('.', 2)
        return [false, nil] unless rest && @facts.key?(head)

        value = @facts[head]
        rest.split('.').each do |k|
          return [false, nil] unless value.is_a?(Hash) && value.key?(k)

          value = value[k]
        end
        [true, value]
      end

      private

      def command(entry)
        raise Error, "#{@path}: each command needs a match, got #{entry.inspect}" unless entry.is_a?(Hash) && entry['match']

        action = (entry['action'] || 'stub').to_s
        raise Error, "#{@path}: command action #{action.inspect} is not one of #{ACTIONS.join(', ')}" unless ACTIONS.include?(action)

        Command.new(match: Regexp.new(entry['match'].to_s), action: action, stdout: entry['stdout'].to_s)
      end
    end
  end
end
