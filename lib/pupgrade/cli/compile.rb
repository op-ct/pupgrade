require 'pupgrade/cli/root'
require 'pupgrade/cli/catalog/compile'

module Pupgrade
  module CLI
    # `pupgrade compile`: `catalog compile` under its shorter name, left
    # out of `pupgrade help`.
    class Compile < Catalog::Compile
      register_command name: 'compile', subcommand_of: Root, hidden: true
      desc Catalog::Compile.desc
    end
  end
end
