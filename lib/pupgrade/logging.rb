require 'driftless/logger'
require 'driftless/ansi'

require 'pupgrade/config_keys'

module Pupgrade
  # pupgrade logs through driftless's logger, so the driftless library code
  # it calls and its own commands write one stream in one format. The level
  # is applied by the CLI, which lets -v / -vv / -q override it.
  module Logging
    extend ConfigKeys::DSL

    config_key 'logging.level', type: :string, default: 'info',
               about: 'debug (progress and per-file detail), info (what each command did), warn, error, or fatal'
  end

  # Terminal colour, shared with driftless's Ansi so both libraries honour
  # one --[no-]color.
  module Output
    extend ConfigKeys::DSL

    config_key 'output.color', type: :boolean, default: nil, example: true,
               about: 'Colour terminal output: true, false, or unset for auto (on when stdout is a TTY). ' \
                      '--[no-]color overrides; NO_COLOR in the environment wins over this file'
  end

  Ansi = ::Driftless::Ansi

  class << self
    def logger
      ::Driftless.logger
    end

    def logger=(logger)
      ::Driftless.logger = logger
    end
  end
end
