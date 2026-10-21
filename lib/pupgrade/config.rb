require 'driftless/config'

module Pupgrade
  # Layered pupgrade.yaml config: driftless's loader (system < user <
  # project, `.include`, `!reference`, array union) pointed at pupgrade's
  # own files. The two files never overlap: pupgrade.yaml holds only the
  # keys pupgrade declares.
  class Config < ::Driftless::Config
    SYSTEM_PATH      = '/etc/puppetlabs/pupgrade/config.yaml'.freeze
    PROJECT_FILENAME = 'pupgrade.yaml'.freeze

    # Where a project keeps pupgrade's files: its config, mocks, and cache.
    PROJECT_DIR = 'pupgrade'.freeze

    # @return [Array<String>] absolute paths in load order
    def self.search_chain
      [SYSTEM_PATH, user_path, project_path]
    end

    # @return [String] `$XDG_CONFIG_HOME/pupgrade/config.yaml`, or its
    #   `~/.config` equivalent
    def self.user_path
      base = ENV['XDG_CONFIG_HOME']
      base = File.expand_path(XDG_CONFIG_DEFAULT) if base.nil? || base.empty?
      File.join(base, 'pupgrade', 'config.yaml')
    end

    # The project config: `pupgrade/pupgrade.yaml`, or `pupgrade.yaml` in
    # the current directory; one or the other, not both.
    #
    # @return [String] the one that exists, else `pupgrade/pupgrade.yaml`
    # @raise [ConfigLoadError] when both exist
    def self.project_path
      candidates = [File.join(Dir.pwd, PROJECT_DIR, PROJECT_FILENAME), File.join(Dir.pwd, PROJECT_FILENAME)]
      present = candidates.select { |p| File.file?(p) }
      raise ConfigLoadError, "both #{candidates.join(' and ')} exist; keep one" if present.size > 1

      present.first || candidates.first
    end
  end

  ConfigLoadError = ::Driftless::ConfigLoadError

  # The process-wide loaded config, set by the CLI's config-load step.
  class << self
    attr_writer :config

    def config
      @config ||= Config.new
    end
  end
end
