require 'spec_helper'

require 'pupgrade/config_keys'
require 'pupgrade/cli/modules/resolve'

RSpec.describe Pupgrade::ConfigKeys do
  it 'knows every key by path, with the class that owns it' do
    owners = described_class.all.to_h { |k| [k.path, k.owner] }
    expect(owners).to include(
      'logging.level'                    => Pupgrade::Logging,
      'output.color'                     => Pupgrade::Output,
      'modules.operatingsystems'         => Pupgrade::ModuleResolver,
      'modules.requirements'             => Pupgrade::ModuleResolver,
      'modules.exclude_modules'          => Pupgrade::ModuleResolver,
      'modules.exclude_dependencies'     => Pupgrade::ModuleResolver,
      'modules.exclude_requirements'     => Pupgrade::ModuleResolver,
      'modules.exclude_operatingsystems' => Pupgrade::ModuleResolver,
      'modules.branchfile'               => Pupgrade::Inputs::Branchfile,
      'modules.resolve_order'            => Pupgrade::CLI::Modules::Resolve,
      'modules.resolve_sort'             => Pupgrade::CLI::Modules::Resolve,
    )
    expect(described_class.subsystems.sort).to eq(%w[logging modules output])
  end

  it 'keeps its registry apart from driftless\'s' do
    expect(Driftless::ConfigKeys['modules.requirements']).to be_nil
    expect(described_class['params.schema_file']).to be_nil
  end
end
