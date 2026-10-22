require 'stringio'
require 'tmpdir'
require 'fileutils'
require 'yaml'

require 'spec_helper'
require 'pupgrade/cli/config/print'

RSpec.describe Pupgrade::CLI::Config::Print do
  before(:all) do # rubocop:disable RSpec/BeforeAfterAll
    @tmp = Dir.mktmpdir
    File.write(File.join(@tmp, 'base.yaml'), YAML.dump('modules' => { 'requirements' => { 'puppet' => '>= 8' } }))
    File.write(File.join(@tmp, 'pupgrade.yaml'), YAML.dump(
      '.include' => ['base.yaml'],
      'solve' => { 'order' => 'oldest' },
      'modules' => { 'operatingsystems' => { 'RedHat' => ['9'] } },
    ))
  end

  after(:all) { FileUtils.rm_rf(@tmp) } # rubocop:disable RSpec/BeforeAfterAll

  around(:each) do |ex|
    original = Pupgrade.instance_variable_get(:@config)
    ex.run
  ensure
    Pupgrade.instance_variable_set(:@config, original)
  end

  before(:each) { silence_logger }

  # [exit status, stdout]
  def run(argv)
    captured = StringIO.new
    original = $stdout
    $stdout  = captured
    status   = nil
    begin
      described_class.new.run(['--config', File.join(@tmp, 'pupgrade.yaml')] + argv)
    rescue SystemExit => e
      status = e.status
    ensure
      $stdout = original
    end
    [status, captured.string]
  end

  it 'prints the merged config, with includes applied, and walks to a key' do
    status, out = run([])
    expect(status).to eq(0)
    expect(YAML.safe_load(out)).to eq(
      'modules' => { 'requirements' => { 'puppet' => '>= 8' }, 'operatingsystems' => { 'RedHat' => ['9'] } },
      'solve'   => { 'order' => 'oldest' },
    )
    expect(run(['solve.order'])).to eq([0, "oldest\n"])
    expect(run(['modules.operatingsystems.RedHat'])).to eq([0, "---\n- '9'\n"])
    expect(YAML.safe_load(run(['modules']).last).keys).to eq(%w[requirements operatingsystems])
  end

  it 'shows declared defaults on request, and a declared key that is unset by its default' do
    _, out = run(['-d', 'solve'])
    expect(YAML.safe_load(out)).to eq('order' => 'oldest', 'include_heads' => false)
    expect(YAML.safe_load(run(['-d']).last).keys).to include('compile', 'surface', 'solve')
    expect(YAML.safe_load(run([]).last).keys).not_to include('compile')
    expect(run(['compile.catalogs_dir'])).to eq([0, "pupgrade/cache/catalogs\n"])
    expect(run(['solve.nope']).first).to eq(3)
    expect(run(['nope']).first).to eq(3)
    expect(run(%w[a b]).first).to eq(2)
  end
end
