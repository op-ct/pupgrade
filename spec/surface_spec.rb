require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'json'

require 'support/fixture_repo'
require 'pupgrade/surface'
require 'pupgrade/surface/diff'

# Surface extraction from the fixture's modules, each in a process of its own.
RSpec.describe Pupgrade::Surface do
  before(:all) do # rubocop:disable RSpec/BeforeAfterAll
    @tmp     = Dir.mktmpdir
    @fixture = Pupgrade::FixtureRepo.build(File.join(@tmp, 'repo'))
    @stdlib  = described_class.extract(File.join(@fixture.dir, 'modules/stdlib'))
  end

  after(:all) { FileUtils.rm_rf(@tmp) } # rubocop:disable RSpec/BeforeAfterAll

  let(:fixture) { @fixture }
  let(:stdlib)  { @stdlib }

  it 'reads classes, every kind of function, and type aliases from stdlib' do
    expect(stdlib).to include('document' => 'surface', 'schema_version' => 2, 'errors' => [])
    expect(stdlib['module']).to eq('name' => 'puppetlabs-stdlib', 'version' => '8.6.0')
    expect(stdlib['classes']).to eq('stdlib' => { 'file' => 'manifests/init.pp', 'params' => { 'version' => { 'type' => 'String', 'default' => "'8.6.0'" } } })
    expect(stdlib['defined_types']).to eq({})
    expect(stdlib['functions'].transform_values { |f| f['kind'] })
      .to eq('legacy_shout' => 'ruby3x', 'stdlib::run_hostname' => 'ruby4x', 'stdlib::shout' => 'ruby4x', 'stdlib::whisper' => 'puppet')
    expect(stdlib['functions']['stdlib::shout']).to eq('kind' => 'ruby4x', 'file' => 'lib/puppet/functions/stdlib/shout.rb',
                                                       'signatures' => [{ 'params' => ['text'], 'type' => 'Callable[String]' }])
    expect(stdlib['functions']['legacy_shout']).to include('arity' => -1, 'type' => 'rvalue')
    expect(stdlib['functions']['stdlib::whisper']).to eq('kind' => 'puppet', 'file' => 'functions/whisper.pp',
                                                         'params' => { 'text' => { 'type' => 'String' } }, 'return_type' => 'String')
    expect(stdlib['type_aliases']).to eq('Stdlib::Port' => { 'file' => 'types/port.pp', 'type' => 'Integer[0, 65535]' })
    expect(stdlib.values_at('types', 'providers', 'facts')).to eq([{}, {}, {}])
  end

  it 'reads a resource type with its attributes, and a provider with its commands' do
    doc = described_class.extract(File.join(fixture.dir, 'modules/firewall'))
    expect(doc['types']['firewall']).to eq(
      'file' => 'lib/puppet/type/firewall.rb', 'ensurable' => true, 'namevars' => ['name'], 'features' => [],
      'params' => {
        'action' => { 'kind' => 'param' },
        'ensure' => { 'kind' => 'property', 'values' => %w[present absent] },
        'name'   => { 'kind' => 'param', 'required' => true },
        'provider' => { 'kind' => 'param' },
      },
    )
    expect(doc['providers']['firewall/iptables']).to eq(
      'type' => 'firewall', 'name' => 'iptables', 'file' => 'lib/puppet/provider/firewall/iptables.rb',
      'confines' => [], 'commands' => ['iptables'], 'defaults' => [], 'features' => [],
    )
    # Puppet loads a type's providers itself; the hook sees a provider named
    # unlike its file, a helper file defines none, and a provider built on a
    # sibling type's provider class finds it
    expect(doc['types'].keys).to eq(%w[conntrack firewall])
    expect(doc['providers'].keys).to eq(%w[conntrack/iptables firewall/iptables firewall/ipv6])
    expect(doc['providers']['firewall/ipv6']).to include('file' => 'lib/puppet/provider/firewall/ip6tables.rb', 'commands' => ['ip6tables'])
    expect(doc['errors']).to eq([])
  end

  it 'reads a defined type and a custom fact' do
    concat  = described_class.extract(File.join(fixture.dir, 'modules/concat'))
    simplib = described_class.extract(File.join(fixture.dir, 'modules/simplib'))
    expect(concat['defined_types']).to eq('concat::fragment' => { 'file' => 'manifests/fragment.pp', 'params' => { 'content' => { 'type' => 'String' } } })
    expect(simplib['facts']).to eq('simplib_fips' => { 'file' => 'lib/facter/simplib_fips.rb', 'kind' => 'custom' })
  end

  it 'reads a provider for a type another module ships, given the modulepath' do
    base = File.join(@tmp, 'mp')
    FileUtils.mkdir_p(File.join(base, 'core/lib/puppet/type'))
    FileUtils.mkdir_p(File.join(base, 'core/lib/puppet_x/core'))
    FileUtils.mkdir_p(File.join(base, 'ext/lib/puppet/provider/widget'))
    File.write(File.join(base, 'core/metadata.json'), '{"name": "x-core", "version": "1.0.0"}')
    File.write(File.join(base, 'core/lib/puppet/type/widget.rb'), "Puppet::Type.newtype(:widget) do\n  newparam(:name, namevar: true)\nend\n")
    File.write(File.join(base, 'core/lib/puppet_x/core/helper.rb'), "module PuppetX; module Core; module Helper; end; end; end\n")
    File.write(File.join(base, 'ext/metadata.json'), '{"name": "x-ext", "version": "1.0.0"}')
    File.write(File.join(base, 'ext/lib/puppet/provider/widget/shiny.rb'),
               "require 'puppet_x/core/helper'\nPuppet::Type.type(:widget).provide(:shiny) do\n  include PuppetX::Core::Helper\nend\n")
    doc = described_class.extract(File.join(base, 'ext'), modulepath: [base])
    expect(doc['errors']).to eq([])
    expect(doc['providers'].keys).to eq(['widget/shiny'])
    expect(doc['source']).to eq('dir' => File.join(base, 'ext'))
  end

  it 'lists a file that fails to load under errors and reads the rest' do
    dir = File.join(@tmp, 'broken')
    FileUtils.mkdir_p(File.join(dir, 'lib/puppet/functions'))
    FileUtils.mkdir_p(File.join(dir, 'manifests'))
    File.write(File.join(dir, 'metadata.json'), '{"name": "x-broken", "version": "0.1.0"}')
    File.write(File.join(dir, 'lib/puppet/functions/bad.rb'), "raise 'boom'\n")
    File.write(File.join(dir, 'manifests/init.pp'), "class broken { }\n")
    File.write(File.join(dir, 'manifests/bad.pp'), "class broken::bad {\n")
    FileUtils.mkdir_p(File.join(dir, 'lib/puppet/type'))
    FileUtils.mkdir_p(File.join(dir, 'lib/puppet/provider/gadget'))
    File.write(File.join(dir, 'lib/puppet/type/gadget.rb'), "Puppet::Type.newtype(:gadget) do\n  newparam(:name, namevar: true)\nend\n")
    File.write(File.join(dir, 'lib/puppet/provider/gadget/bad.rb'), "raise 'no provider today'\n")
    File.write(File.join(dir, 'lib/puppet/provider/gadget/fine.rb'), "Puppet::Type.type(:gadget).provide(:fine) do\nend\n")
    doc = described_class.extract(dir)
    expect(doc['classes'].keys).to eq(['broken'])
    expect(doc['types'].keys).to eq(['gadget'])
    expect(doc['providers'].keys).to eq(['gadget/fine'])
    expect(doc['errors']).to contain_exactly(a_string_matching(%r{\Alib/puppet/functions/bad.rb: RuntimeError: boom}),
                                            a_string_matching(%r{\Amanifests/bad.pp: parse error}),
                                            a_string_matching(%r{\Alib/puppet/provider/gadget/bad.rb: .*no provider today}))
  end

  it 'reads a module at a ref of its remote, and loads a document it wrote' do
    doc = described_class.checkout(File.join(fixture.remotes_dir, 'puppetlabs-stdlib.git'), 'v9.6.0') { |dir| described_class.extract(dir) }
    expect(doc['module']['version']).to eq('9.6.0')
    expect(doc['functions'].keys).not_to include('legacy_shout')
    path = File.join(@tmp, 'stdlib-9.json')
    File.write(path, JSON.generate(doc))
    expect(described_class.load(path)['module']['version']).to eq('9.6.0')
    expect { described_class.checkout(File.join(fixture.remotes_dir, 'puppetlabs-stdlib.git'), 'v0') { nil } }.to raise_error(described_class::Error, /git fetch/)
    expect { described_class.load(File.join(@tmp, 'nope')) }.to raise_error(described_class::Error, /no such file/)
    File.write(path, JSON.generate(doc.merge('schema_version' => 99)))
    expect { described_class.load(path) }.to raise_error(described_class::Error, /schema 99 is newer than this pupgrade reads \(2\)/)
    expect { described_class.extract(File.join(@tmp, 'nope')) }.to raise_error(described_class::Error, /no such directory/)
  end

  describe Pupgrade::Surface::Diff do
    it 'lists the module, entries added and removed, and each attribute that changed' do
      newer = Pupgrade::Surface.checkout(File.join(fixture.remotes_dir, 'puppetlabs-stdlib.git'), 'v9.6.0') { |dir| Pupgrade::Surface.extract(dir) }
      changes = described_class.documents(stdlib, newer)
      expect(changes.map { |c| [c.section, c.name, c.kind, c.path] }).to eq([
        ['module', 'version', 'changed', []],
        ['metadata', 'CentOS', 'removed', ['operatingsystem_support']],
        ['metadata', 'Debian', 'changed', ['operatingsystem_support']],
        ['metadata', 'RedHat', 'changed', ['operatingsystem_support']],
        ['metadata', 'Rocky', 'added', ['operatingsystem_support']],
        ['metadata', 'Ubuntu', 'changed', ['operatingsystem_support']],
        ['classes', 'stdlib', 'changed', %w[params version default]],
        ['functions', 'legacy_shout', 'removed', []],
        ['functions', 'stdlib::shout', 'changed', %w[signatures]],
        ['type_aliases', 'Stdlib::Port', 'changed', %w[type]],
      ])
      expect(changes.map { |c| [c.old, c.new] }.values_at(0, 1, 4, 6, 9)).to eq([
        %w[8.6.0 9.6.0], [%w[7], nil], [nil, %w[8 9]], ["'8.6.0'", "'9.6.0'"], ['Integer[0, 65535]', 'Integer[1, 65535]'],
      ])
      expect(changes.map(&:detail).values_at(0, 1, 3, 6, 7, 8, 9)).to eq([
        '8.6.0 -> 9.6.0',
        'was ["7"]',
        'operatingsystem_support: ["7","8"] -> ["8","9"]',
        "params.version.default: '8.6.0' -> '9.6.0'",
        'was ruby3x, in lib/puppet/parser/functions/legacy_shout.rb',
        'signatures: [{"params":["text"],"type":"Callable[String]"}] -> [{"params":["text","times"],"type":"Callable[String, Integer, 1, 2]"}]',
        'type: Integer[0, 65535] -> Integer[1, 65535]',
      ])
      expect(described_class.documents(stdlib, stdlib)).to eq([])
    end

    it 'names an added attribute at the level it appears' do
      a = { 'module' => {}, 'types' => { 't' => { 'params' => { 'x' => { 'kind' => 'param' } } } } }
      b = { 'module' => {}, 'types' => { 't' => { 'params' => { 'x' => { 'kind' => 'param', 'required' => true }, 'y' => { 'kind' => 'property' } } } } }
      expect(described_class.documents(a, b).map(&:detail)).to eq(['params.x.required: added true', 'params.y: added {"kind":"property"}'])
    end
  end
end
