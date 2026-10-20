require 'pupgrade/config'
require 'pupgrade/config_keys'

module Pupgrade
  # Strict validator for a loaded {Pupgrade::Config}: rejects unknown
  # top-level subsystem keys and unknown keys within a subsystem, with a
  # {DidYouMean} suggestion when a typo has a close match. A key starting
  # with `.` is not checked at any level: it is the place for YAML anchors
  # other keys alias.
  #
  # Raises {Pupgrade::ConfigValidationError} on the first problem found.
  class ConfigValidator
    def initialize(config)
      @config = config
    end

    def validate!
      check_top_level_keys
      check_withheld_keys
      check_subsystem_keys
    end

    # Every subsystem some class has declared a key for.
    def self.known_subsystems
      ConfigKeys.subsystems.uniq.sort
    end

    private

    def check_top_level_keys
      known   = self.class.known_subsystems
      unknown = @config.to_h.keys.reject { |k| anchor_holder?(k) } - known
      return if unknown.empty?

      first = unknown.first
      msg   = "unknown top-level config key: #{first.inspect}"
      msg +=
        if (sug = suggest(first, known))
          " (did you mean #{sug.inspect}?)"
        else
          " (known: #{known.join(', ')})"
        end
      raise ConfigValidationError, msg
    end

    def check_withheld_keys
      ConfigKeys.withheld.each do |key|
        next if @config.dig(key.subsystem, key.name).nil?
        raise ConfigValidationError, "#{key.path} cannot be set in config: #{key.because}"
      end
    end

    # Rejects any key in a subsystem section that no class declared.
    def check_subsystem_keys
      @config.to_h.each do |subsystem, body|
        next if anchor_holder?(subsystem)
        next unless body.is_a?(Hash)

        walk_keys(subsystem, [], body, ConfigKeys.settable(subsystem).map { |k| k.name.split('.') })
      end
    end

    # Raises on any key under body that no declared name covers.
    # A dotted name matches one segment per nesting level.
    #
    # @param subsystem [String] the section, for error messages
    # @param prefix [Array<String>] segments matched so far
    # @param body [Hash] the mapping under prefix
    # @param paths [Array<Array<String>>] declared names as segments, with
    #   prefix segments already trimmed
    # @raise [ConfigValidationError]
    def walk_keys(subsystem, prefix, body, paths)
      body.each do |key, value|
        next if anchor_holder?(key)

        dotted = (prefix + [key.to_s]).join('.')
        deeper = paths.select { |p| p.first == key }
        next if deeper.any? { |p| p.size == 1 }

        if deeper.any?
          unless value.is_a?(Hash)
            raise ConfigValidationError,
                  "#{subsystem}.#{dotted} holds nested keys " \
                  "(#{deeper.map { |p| p.drop(1).join('.') }.join(', ')}), not a value"
          end
          walk_keys(subsystem, prefix + [key.to_s], value, deeper.map { |p| p.drop(1) })
          next
        end

        known = paths.map { |p| p.join('.') }
        if known.include?(key.to_s)
          raise ConfigValidationError,
                "#{subsystem} key #{key.inspect} must be spelled as nested mappings, not a dotted key"
        end
        msg = "unknown #{subsystem} config key: #{dotted.inspect}"
        msg +=
          if (sug = suggest(key.to_s, known))
            " (did you mean #{sug.inspect}?)"
          else
            " (known: #{known.join(', ')})"
          end
        raise ConfigValidationError, msg
      end
    end

    # A key kept for the anchors it holds, never read as a setting.
    def anchor_holder?(key)
      key.to_s.start_with?('.')
    end

    def suggest(input, candidates)
      require 'did_you_mean'
      DidYouMean::SpellChecker.new(dictionary: candidates).correct(input.to_s).first
    rescue LoadError
      nil
    end
  end

  # Raised by {ConfigValidator} for any strict-check violation.
  class ConfigValidationError < StandardError; end
end
