require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'stringio'
require 'json'

require 'support/fixture_repo'
require 'pupgrade/cli/catalog'
require 'pupgrade/compile/session'

# `catalog diff` between two compiles of the fixture: before and after an
# edit to the profile and its data.
RSpec.describe Pupgrade::CLI::Catalog::Diff do
  before(:all) do # rubocop:disable RSpec/BeforeAfterAll
    @tmp     = Dir.mktmpdir
    @fixture = Pupgrade::FixtureRepo.build(File.join(@tmp, 'repo'))
    @before  = File.join(@tmp, 'before')
    @after   = File.join(@tmp, 'after')
    compile_into(@before, %w[web01.example.com db01.example.com])

    profile = File.join(@fixture.dir, 'site-modules/profile/manifests/base.pp')
    text = File.read(profile)
    text.sub!("action   => 'accept',", "action   => 'drop',")
    text.sub!("concat::fragment { 'motd':", "file { '/etc/motd': ensure => file }\n  concat::fragment { 'motd':")
    File.write(profile, text)
    File.write(File.join(@fixture.dir, 'data/common.yaml'), File.read(File.join(@fixture.dir, 'data/common.yaml')).sub('time.example.com', 'ntp.example.com'))
    compile_into(@after, %w[web01.example.com])
  end

  after(:all) { FileUtils.rm_rf(@tmp) } # rubocop:disable RSpec/BeforeAfterAll

  def compile_into(dir, certnames)
    session = Pupgrade::Compile::Session.new(repo_dir: @fixture.dir, mocks: Pupgrade::Compile::Mocks.load(@fixture.mocks)).start
    Pupgrade::Compile::Factset.load_all([@fixture.factsets]).select { |f| certnames.include?(f.certname) }.each do |factset|
      result = session.compile(factset)
      raise result.error if result.error

      FileUtils.mkdir_p(File.join(dir, factset.certname))
      File.write(File.join(dir, factset.certname, 'catalog.json'), JSON.pretty_generate(result.catalog))
    end
  ensure
    session&.close
  end

  # [exit status, stdout]
  def run(argv)
    captured = StringIO.new
    original = $stdout
    $stdout  = captured
    status   = nil
    begin
      described_class.new.run(argv)
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

  it 'lists what changed per node, and the node only one run has' do
    status, out = run([@before, @after])
    expect(status).to eq(1)
    rows = cells(out)
    expect(rows.first).to eq(%w[certname change resource parameter detail])
    expect(rows.drop(1).map { |r| r.first(4) }).to eq([
      ['db01.example.com', 'node-missing', '', ''],
      ['web01.example.com', 'param-changed', 'Class[Profile::Base]', 'ntp_servers'],
      ['web01.example.com', 'param-changed', 'Concat::Fragment[motd]', 'content'],
      ['web01.example.com', 'resource-added', 'File[/etc/motd]', ''],
      ['web01.example.com', 'param-changed', 'Firewall[100 allow ntp 123]', 'action'],
      ['web01.example.com', 'param-changed', 'Notify[fragment motd]', 'message'],
      ['web01.example.com', 'edge-added', 'Class[Profile::Base] -> File[/etc/motd]', ''],
    ])
    expect(rows[1].last).to eq("only in #{@before}")
    expect(rows[2].last).to eq('["time.example.com"] -> ["ntp.example.com"]')
    expect(rows[4].last).to match(%r{\Asite-modules/profile/manifests/base.pp:\d+\z})
    expect(rows[5].last).to eq('"accept" -> "drop"')
    expect(rows[6].last).to include('time.example.com', 'ntp.example.com')
  end

  it 'groups identical changes across nodes, summarises per node, and filters' do
    _, out = run(['--group', @before, @after])
    rows = cells(out)
    expect(rows.first).to eq(%w[change resource parameter detail nodes])
    expect(rows.drop(1).map { |r| [r[0], r[4]] }).to include(['param-changed', 'web01.example.com'], ['node-missing', 'db01.example.com'])

    _, out = run(['--summary', @before, @after])
    expect(cells(out)).to eq([
      %w[certname resources params classes edges total],
      ['db01.example.com', '0', '0', '0', '0', '1'],
      ['web01.example.com', '+1', '~4', '0', '+1', '6'],
    ])

    status, out = run(['--changes', 'param-changed', '--resources', 'Firewall*', @before, @after])
    expect(status).to eq(1)
    expect(cells(out).size).to eq(2)
    status, out = run(['--ignore-params', 'action,message,content,ntp_servers', '--skip-changes', 'node-missing,resource-added,edge-added', @before, @after])
    expect([status, out]).to eq([0, "(nothing matches)\n"])
    # an entity stands for its kinds, a glob for those it matches
    _, out = run(['--changes', 'param', '--skip-changes', '*-changed', @before, @after])
    expect(out).to eq("(nothing matches)\n")
    _, out = run(['--changes', 'resource,edge-*', @before, @after])
    expect(cells(out).drop(1).map { |r| r[1] }).to eq(%w[resource-added edge-added])
    # a class parameter, by its class and its name
    _, out = run(['--resources', 'Class[profile::*]', '--params', 'ntp_*', @before, @after])
    expect(cells(out).drop(1).map { |r| r[2, 2] }).to eq([['Class[Profile::Base]', 'ntp_servers']])
    _, out = run(['--params', 'content,action', @before, @after])
    expect(cells(out).drop(1).map { |r| r[3] }).to eq(%w[content action])
    expect(run(['--changes', 'bogus', @before, @after]).first).to eq(2)
    expect(run(['--skip-changes', 'nothing-*', @before, @after]).first).to eq(2)
    expect(run([@before]).first).to eq(2)
    expect(run([@before, File.join(@tmp, 'nope')]).first).to eq(3)
  end

  it 'compares one node directory with another, and the same run with itself' do
    status, out = run([File.join(@before, 'web01.example.com'), File.join(@after, 'web01.example.com')])
    expect(status).to eq(1)
    expect(cells(out).drop(1).map(&:first).uniq).to eq(['web01.example.com'])
    expect(run([@before, @before])).to eq([0, "(nothing matches)\n"])
  end

  it 'is reached from compile, which still compiles when no subcommand is named' do
    expect(Pupgrade::CLI::Catalog.find_subcommand('diff')).to eq(described_class)
    captured = StringIO.new
    original = $stdout
    $stdout  = captured
    status   = nil
    begin
      Pupgrade::CLI::Catalog.new.run(['di', @before, @before])
    rescue SystemExit => e
      status = e.status
    ensure
      $stdout = original
    end
    expect([status, captured.string]).to eq([0, "(nothing matches)\n"])
  end
end
