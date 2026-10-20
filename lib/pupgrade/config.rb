require 'driftless/config'

module Pupgrade
  # Layered pupgrade.yaml config: driftless's loader (system < user <
  # project, `.include`, `!reference`, array union) pointed at pupgrade's
  # own files. The two files never overlap: pupgrade.yaml holds only the
  # keys pupgrade declares.
  class Config < ::Driftless::Config
    SYSTEM_PATH      = '/etc/puppetlabs/pupgrade/config.yaml'.freeze
    PROJECT_FILENAME = 'pupgrade.yaml'.freeze

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

    # @return [String] pupgrade.yaml in the current directory
    def self.project_path
      File.join(Dir.pwd, PROJECT_FILENAME)
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
