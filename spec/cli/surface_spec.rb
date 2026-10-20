require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'stringio'
require 'json'

require 'support/fixture_repo'
require 'pupgrade/cli/surface'

RSpec.describe Pupgrade::CLI::Surface do
  before(:all) do # rubocop:disable RSpec/BeforeAfterAll
    @tmp     = Dir.mktmpdir
    @fixture = Pupgrade::FixtureRepo.build(File.join(@tmp, 'repo'))
  end

  after(:all) { FileUtils.rm_rf(@tmp) } # rubocop:disable RSpec/BeforeAfterAll

  let(:fixture) { @fixture }

  # [exit status, stdout]
  def run(command, argv)
    captured = StringIO.new
    original = $stdout
    $stdout  = captured
    status   = nil
    begin
      command.new.run(argv)
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

  it 'prints a module directory\'s document, writes a ref\'s to a file, and refuses bad arguments' do
    status, out = run(described_class, [File.join(fixture.dir, 'modules/concat')])
    expect(status).to eq(0)
    doc = JSON.parse(out)
    expect(doc['defined_types'].keys).to eq(['concat::fragment'])
    expect(doc['source']).to eq(File.join(fixture.dir, 'modules/concat'))

    path = File.join(@tmp, 'stdlib-9.json')
    status, out = run(described_class, ['--git', File.join(fixture.remotes_dir, 'puppetlabs-stdlib.git'), '--ref', 'v9.6.0', '-o', path])
    expect([status, out]).to eq([0, "#{path}\n"])
    expect(JSON.parse(File.read(path))['source']).to end_with('puppetlabs-stdlib.git@v9.6.0')

    expect(run(described_class, []).first).to eq(2)
    expect(run(described_class, ['--git', 'x']).first).to eq(2)
    expect(run(described_class, [File.join(@tmp, 'nope')]).first).to eq(3)
  end

  it 'diffs two sides given as a directory and a document, with filters and a summary' do
    path = File.join(@tmp, 'stdlib-9.json')
    run(described_class, ['--git', File.join(fixture.remotes_dir, 'puppetlabs-stdlib.git'), '--ref', 'v9.6.0', '-o', path])
    stdlib = File.join(fixture.dir, 'modules/stdlib')

    status, out = run(described_class, ['diff', stdlib, path])
    expect(status).to eq(1)
    expect(cells(out).map { |r| r.first(3) }).to eq([
      %w[surface name change],
      %w[module version changed],
      %w[classes stdlib changed],
      %w[functions legacy_shout removed],
      %w[functions stdlib::shout changed],
      %w[type_aliases Stdlib::Port changed],
    ])

    _, out = run(described_class, ['diff', '--surfaces', 'functions', '--changes', 'removed', stdlib, path])
    expect(cells(out).drop(1).map { |r| r[1] }).to eq(['legacy_shout'])
    _, out = run(described_class, ['diff', '--summary', stdlib, path])
    expect(cells(out)).to eq([%w[surface added removed changed total], %w[module 0 0 1 1], %w[classes 0 0 1 1], %w[functions 0 1 1 2], %w[type_aliases 0 0 1 1]])
    expect(run(described_class, ['diff', stdlib, stdlib])).to eq([0, "(nothing matches)\n"])
    expect(run(described_class, ['diff', '--surfaces', 'bogus', stdlib, path]).first).to eq(2)
    expect(run(described_class, ['diff', stdlib]).first).to eq(2)
  end
end
