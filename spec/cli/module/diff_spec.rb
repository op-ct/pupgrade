require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'stringio'

require 'support/fixture_repo'
require 'pupgrade/cli/module/diff'

RSpec.describe Pupgrade::CLI::ModuleCommand::Diff do
  before(:all) do # rubocop:disable RSpec/BeforeAfterAll
    @tmp     = Dir.mktmpdir
    @fixture = Pupgrade::FixtureRepo.build(File.join(@tmp, 'repo'))
  end

  after(:all) { FileUtils.rm_rf(@tmp) } # rubocop:disable RSpec/BeforeAfterAll

  let(:fixture) { @fixture }
  let(:cache)   { File.join(fixture.dir, 'pupgrade/cache/api_surfaces') }

  # [exit status, stdout]
  def run(argv)
    captured = StringIO.new
    original = $stdout
    $stdout  = captured
    status   = nil
    begin
      described_class.new.run(['--no-config', '--no-color', '-d', fixture.dir] + argv)
    rescue SystemExit => e
      status = e.status
    ensure
      $stdout = original
    end
    [status, captured.string]
  end

  def cells(output)
    output.lines.map(&:rstrip).reject { |l| l.start_with?('--') }.map { |l| l.split('|', -1).map(&:strip) }
  end

  before(:each) { silence_logger }

  it 'diffs modules at refs, documents, and directories: metadata first, then the surfaces, as phrases' do
    status, out = run(['stdlib', 'stdlib:v9.6.0'])
    expect(status).to eq(1)
    expect(cells(out)).to eq([
      %w[item difference detail],
      ['module version', 'changed major release', '8.6.0 -> 9.6.0'],
      ['OS CentOS', 'removed', 'was 7'],
      ['OS Debian', 'changed', '10, 11 -> 11, 12'],
      ['OS RedHat', 'changed', '7, 8 -> 8, 9'],
      ['OS Rocky', 'added', '8, 9'],
      ['OS Ubuntu', 'changed', '18.04, 20.04 -> 20.04, 22.04'],
      ['class stdlib::version', 'changed param default', "'8.6.0' -> '9.6.0'"],
      ['function legacy_shout', 'removed', 'was ruby3x, in lib/puppet/parser/functions/legacy_shout.rb'],
      ['function stdlib::shout', 'changed signatures', '(text) -> (text, times)'],
      ['type alias Stdlib::Port', 'changed type', 'Integer[0, 65535] -> Integer[1, 65535]'],
    ])

    stdlib = File.join(fixture.dir, 'modules/stdlib')
    newer  = File.join(cache, fixture.surface_file('stdlib', '9.6.0', 'v9.6.0'))
    _, out = run(['--surfaces', 'functions', '--changes', 'removed', stdlib, newer])
    expect(cells(out).drop(1).map(&:first)).to eq(['function legacy_shout'])
    _, out = run(['--summary', stdlib, newer])
    expect(cells(out)).to eq([%w[surface added removed changed total], %w[module 0 0 1 1], %w[metadata 1 1 3 5], %w[classes 0 0 1 1],
                              %w[functions 0 1 1 2], %w[type_aliases 0 0 1 1]])
    expect(run([stdlib, stdlib])).to eq([0, "(nothing matches)\n"])
    expect(run(['--surfaces', 'bogus', stdlib, newer]).first).to eq(2)
    expect(run([stdlib]).first).to eq(2)
    expect(run(['stdlib', 'nope']).first).to eq(3)
  end

  it 'shows every value whole as blocks with --full' do
    _, out = run(['--full', '--surfaces', 'functions,type_aliases', 'stdlib', 'stdlib:v9.6.0'])
    expect(out).to eq(<<~TEXT)
      function legacy_shout: removed
        - ruby3x, in lib/puppet/parser/functions/legacy_shout.rb

      function stdlib::shout: changed signatures
        - (text)
        + (text, times)

      type alias Stdlib::Port: changed type
        - Integer[0, 65535]
        + Integer[1, 65535]
    TEXT
  end
end
