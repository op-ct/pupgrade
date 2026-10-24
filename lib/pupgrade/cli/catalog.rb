require 'pupgrade/cli/base'
require 'pupgrade/cli/root'

module Pupgrade
  module CLI
    # `pupgrade catalog`: the parent of the commands that compile catalogs
    # from factsets and read what the compiles left in the cache.
    class Catalog < Base
      register_command name: 'catalog', subcommand_of: Root
      desc 'Catalogs compiled from factsets: compile them, list and show what was compiled, diff two runs'
    end
  end
end

Dir[File.join(__dir__, 'catalog', '*.rb')].sort.each { |f| require f }
