require 'spec_helper'

require 'pupgrade/surface/render'

RSpec.describe Pupgrade::Surface::Render do
  def change(section, name, path, kind, old, new)
    Pupgrade::Surface::Diff::Change.new(section: section, name: name, path: path, kind: kind, old: old, new: new)
  end

  it 'folds bracketed parts to […], showing what Optional wraps' do
    expect(described_class.abbreviate('Variant[Array[Variant[String, Hash]], String, Hash, Undef]')).to eq('Variant[…]')
    expect(described_class.abbreviate('Optional[Variant[Array[Variant[String, Hash]], String, Hash]]')).to eq('Optional[Variant[…]]')
    expect(described_class.abbreviate('Optional[Optional[String]]')).to eq('Optional[Optional[String]]')
    expect(described_class.abbreviate("Struct[{\n  'a' => String,\n  'b' => Integer\n}]")).to eq('Struct[…]')
    expect(described_class.abbreviate("[1,\n 2]")).to eq('[…]')
    expect(described_class.abbreviate('Enum[a, b')).to eq('Enum[a, b')
    expect(described_class.abbreviate('x' * 80)).to eq("#{'x' * 69}…")
  end

  it 'names the item and phrases the difference' do
    c = change('defined_types', 'puppet_authorization::rule', %w[params allow type], 'changed', 'Variant[String, Undef]', 'Optional[String]')
    expect(described_class.item(c)).to eq('defined type puppet_authorization::rule::allow')
    expect(described_class.difference(c)).to eq('changed param type')
    expect(described_class.detail(c)).to eq('Variant[…] -> Optional[String]')

    expect(described_class.difference(change('module', 'version', [], 'changed', '1.0.0', '2.0.0'))).to eq('changed major release')
    expect(described_class.difference(change('module', 'version', [], 'changed', 'v1.2.0', '1.3.1'))).to eq('changed minor release')
    expect(described_class.difference(change('module', 'version', [], 'changed', '1.2.0', '1.2.1'))).to eq('changed patch release')
    expect(described_class.difference(change('module', 'version', [], 'changed', 'x', '1.2.1'))).to eq('changed version')
    expect(described_class.difference(change('classes', 'a', %w[params p], 'changed', nil, { 'type' => 'String' }))).to eq('added required param')
    expect(described_class.difference(change('classes', 'a', %w[params p], 'changed', nil, { 'default' => '1' }))).to eq('added param')
    expect(described_class.difference(change('classes', 'a', %w[params p], 'changed', { 'default' => '1' }, nil))).to eq('removed param')
    expect(described_class.difference(change('classes', 'a', %w[params p default], 'changed', nil, '1'))).to eq('added param default')
    expect(described_class.difference(change('types', 't', %w[params ensure values], 'changed', %w[a], %w[a b]))).to eq('changed param values')
    expect(described_class.item(change('types', 't', %w[params ensure values], 'changed', %w[a], %w[a b]))).to eq('type t ensure')
    expect(described_class.difference(change('functions', 'f', %w[return_type], 'changed', 'String', 'Integer'))).to eq('changed return type')
    expect(described_class.difference(change('metadata', 'puppetlabs/stdlib', %w[dependencies], 'added', nil, '>= 9.0.0'))).to eq('added')
    expect(described_class.item(change('metadata', 'RedHat', %w[operatingsystem_support], 'removed', %w[7], nil))).to eq('OS RedHat')
    expect(described_class.detail(change('metadata', 'RedHat', %w[operatingsystem_support], 'removed', %w[7], nil))).to eq('was 7')
    expect(described_class.item(change('facts', 'os_fingerprint', [], 'added', nil, { 'file' => 'lib/facter/x.rb' }))).to eq('fact os_fingerprint')
  end

  it 'lays a change out as a block with the values whole' do
    c = change('type_aliases', 'Stdlib::Port', %w[type], 'changed', "Integer[0,\n  65535]", 'Integer[1, 65535]')
    expect(described_class.block(c)).to eq(['type alias Stdlib::Port: changed type', '  - Integer[0,', '      65535]', '  + Integer[1, 65535]'])
  end
end
