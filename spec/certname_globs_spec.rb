require 'spec_helper'

require 'pupgrade/certname_globs'

RSpec.describe Pupgrade::CertnameGlobs do
  it 'keeps what a plain glob matches and leaves out what a ! glob matches, case-insensitive' do
    names = %w[web01.example.com web02.example.com db01.example.com]
    pick  = ->(globs) { names.select { |n| described_class.match?(globs, n) } }
    expect(pick.call(nil)).to eq(names)
    expect(pick.call(['WEB*'])).to eq(%w[web01.example.com web02.example.com])
    expect(pick.call(['!db*'])).to eq(%w[web01.example.com web02.example.com])
    expect(pick.call(['*.example.com', '!web02*'])).to eq(%w[web01.example.com db01.example.com])
    expect(pick.call(['web*', '!web*'])).to eq([])
  end
end
