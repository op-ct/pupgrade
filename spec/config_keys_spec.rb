require 'spec_helper'

require 'pupgrade/config_keys'
require 'pupgrade/cli/check'
require 'pupgrade/cli/compile'
require 'pupgrade/cli/solve'
require 'pupgrade/cli/impact'
require 'pupgrade/cli/surface'

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
      'modules.check_order'              => Pupgrade::CLI::Check,
      'modules.check_sort'               => Pupgrade::CLI::Check,
      'compile.factsets'                 => Pupgrade::CLI::Compile,
      'compile.output_dir'               => Pupgrade::CLI::Compile,
      'compile.environment'              => Pupgrade::Compile::Session,
      'compile.manifest'                 => Pupgrade::Compile::Session,
      'compile.prepend_file'             => Pupgrade::Compile::Session,
      'compile.mocks'                    => Pupgrade::Compile::Session,
      'compile.default_mocks'            => Pupgrade::Compile::Session,
      'compile.on_leak'                  => Pupgrade::Compile::Session,
      'compile.vars'                     => Pupgrade::Compile::Session,
      'compile.server_facts'             => Pupgrade::Compile::Session,
      'solve.order'                      => Pupgrade::CLI::Solve,
      'solve.include_heads'              => Pupgrade::CLI::Solve,
      'solve.evidence_dir'               => Pupgrade::CLI::Solve,
      'impact.evidence_dir'              => Pupgrade::CLI::Impact,
      'surface.cache_dir'                => Pupgrade::CLI::Surface,
    )
    expect(described_class.subsystems.sort).to eq(%w[compile impact logging modules output solve surface])
  end

  it 'keeps its registry apart from driftless\'s' do
    expect(Driftless::ConfigKeys['modules.requirements']).to be_nil
    expect(described_class['params.schema_file']).to be_nil
  end
end
