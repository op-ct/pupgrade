require 'yaml'

require 'pupgrade/cli/base'
require 'pupgrade/cli/config'
require 'pupgrade/config_keys'

module Pupgrade
  module CLI
    class Config
      # `pupgrade config print`
      #
      # The configuration as this run resolves it: every file in the search
      # chain merged, includes and references applied, as YAML. A dotted key
      # narrows it to that subtree. Keys left unset are shown with their
      # declared defaults on request.
      class Print < Base
        register_command name: 'print', subcommand_of: Config
        positional '[<subsystem>[.<key>...]]'
        desc 'Print the resolved configuration, or one subtree of it'

        def execute(argv)
          reject_extra_args!(argv, max: 1)
          data = ::Pupgrade.config.to_h
          data = with_defaults(data) if @options[:include_defaults]
          sources = ::Pupgrade.config.sources

          if (key = argv.first)
            found, value = lookup(data, key)
            unless found
              declared = ::Pupgrade::ConfigKeys[key]
              fatal!("config print: nothing at #{key.inspect}", 3) unless declared && !declared.withheld?
              ::Pupgrade.logger.notice("config print: #{key} is unset; this is its default")
              value = declared.default
            end
            puts((value.is_a?(Hash) || value.is_a?(Array)) ? YAML.dump(value) : value.to_s)
          else
            puts YAML.dump(data)
          end
          ::Pupgrade.logger.notice(sources.empty? ? 'config print: no config file loaded' : "config print: from #{sources.join(', ')}")
          exit 0
        end

        protected

        def configure_parser(o)
          o.on('-d', '--[no-]include-defaults', 'Show keys left unset with their declared defaults') { |v| @options[:include_defaults] = v }
          o.separator ''
          o.separator 'Reads the same files every command does; --config and --no-config apply.'
        end

        private

        # @return [Array(Boolean, Object)] whether the dotted key is set, and its value
        def lookup(data, key)
          key.split('.').reduce([true, data]) do |(found, v), k|
            (found && v.is_a?(Hash) && v.key?(k)) ? [true, v[k]] : [false, nil]
          end
        end

        # The merged config with each unset key's default added, for keys
        # declaring one.
        def with_defaults(data)
          merged = Marshal.load(Marshal.dump(data))
          ::Pupgrade::ConfigKeys.all.reject(&:withheld?).each do |key|
            next if key.default.nil?

            segments = [key.subsystem] + key.name.split('.')
            parent = segments[0..-2].reduce(merged) do |h, k|
              h[k] = {} unless h[k].is_a?(Hash)
              h[k]
            end
            parent[segments.last] = key.default unless parent.key?(segments.last)
          end
          merged
        end
      end
    end
  end
end
