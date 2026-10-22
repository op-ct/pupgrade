require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'stringio'

require 'support/fixture_repo'
require 'pupgrade/cli/check'

# `check` against the fixture control repo: the where-to-start
# views on a proposal that moves stdlib a major version.
RSpec.describe Pupgrade::CLI::Check do
  before(:all) do # rubocop:disable RSpec/BeforeAfterAll
    @tmp     = Dir.mktmpdir
    @fixture = Pupgrade::FixtureRepo.build(File.join(@tmp, 'repo'))
  end

  after(:all) { FileUtils.rm_rf(@tmp) } # rubocop:disable RSpec/BeforeAfterAll

  let(:fixture) { @fixture }

  # [exit status, stdout]
  def run(argv)
    out      = StringIO.new
    original = $stdout
    $stdout  = out
    status   = nil
    begin
      described_class.new.run(['-c', fixture.config, '-d', fixture.dir, '--propose', fixture.proposed] + argv)
    rescue SystemExit => e
      status = e.status
    ensure
      $stdout = original
    end
    [status, out.string]
  end

  def cells(output)
    output.lines.map(&:rstrip).reject { |l| l.start_with?('--') }.map { |l| l.split('|', -1).map(&:strip) }
  end

  around(:each) do |ex|
    original = Pupgrade.instance_variable_get(:@config)
    ex.run
  ensure
    Pupgrade.instance_variable_set(:@config, original)
  end

  it 'shows every row with its mark, narrows to the changed ones on request, and counts them' do
    log = capture_log(level: :info) do
      status, out = run([])
      expect(status).to eq(1)
      expect(cells(out).drop(1).map(&:first).tally).to eq('+' => 30, '-' => 12, '' => 58)
    end
    expect(log).to include('30 introduced, 12 resolved, 58 unchanged;')

    log = capture_log(level: :info) do
      _, out = run(['--changed-only'])
      expect(cells(out).drop(1).map(&:first).tally).to eq('+' => 30, '-' => 12)
    end
    expect(log).to include('58 unchanged (hidden)')
    _, out = run(['--hide-resolved'])
    expect(cells(out).drop(1).map(&:first).tally).to eq('+' => 30, '' => 58)
  end

  it 'summarises introduced and resolved rows per module' do
    _, out = run(['--summary'])
    rows = cells(out)
    expect(rows.first).to eq(%w[module missing-dependency dependency-version puppet-version operatingsystem total])
    expect(rows.assoc('puppetlabs-tomcat')).to eq(['puppetlabs-tomcat', '0', '-2', '0', '0', '-2'])
    expect(rows.assoc('puppet-nginx')).to eq(['puppet-nginx', '0', '+2', '0', '=2', '+2 =2'])
    _, out = run(['--summary', '--changed-only'])
    expect(cells(out).assoc('puppet-nginx')).to eq(['puppet-nginx', '0', '+2', '0', '0', '+2'])
  end

  it 'groups by the changed entry, stdlib first, and names what moved' do
    _, out = run(['--by-change'])
    headings = out.lines.grep(/\A\S.*\(\+\d+ -\d+\)$/).map(&:chomp)
    expect(headings.first).to match(%r{\Apuppetlabs-stdlib \(modules/stdlib\): tag v8\.6\.0 -> tag v9\.6\.0 \(\+2\d -\d+\)\z})
    expect(headings.map { |h| h[/\A\S+/] }).to eq(%w[puppetlabs-stdlib puppetlabs-concat puppetlabs-puppetdb puppetlabs-apache puppetlabs-postgresql puppetlabs-apt])
    expect(headings).not_to include(a_string_starting_with('(no changed entry'))
    # every introduced and resolved row lands in at least one group
    all_rows = cells(run(['--changed-only']).last).drop(1)
    grouped  = cells(out).reject { |r| r.size < 2 }.reject { |r| r.first == 'change' }
    expect(grouped.uniq.size).to eq(all_rows.size)
  end
end
