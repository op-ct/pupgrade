require 'spec_helper'

require 'pupgrade/surface/render'

RSpec.describe Pupgrade::Surface::Render do
  def change(section, name, path, kind, old, new)
    Pupgrade::Surface::Diff::Change.new(section: section, name: name, path: path, kind: kind, old: old, new: new)
  end

  it 'folds the bracketed part of unbounded types to […], keeping bounds and what Optional wraps' do
    expect(described_class.abbreviate('Variant[Array[Variant[String, Hash]], String, Hash, Undef]')).to eq('Variant[…]')
    expect(described_class.abbreviate('Optional[Variant[Array[Variant[String, Hash]], String, Hash]]')).to eq('Optional[Variant[…]]')
    expect(described_class.abbreviate('Optional[Optional[String]]')).to eq('Optional[Optional[String]]')
    expect(described_class.abbreviate("Struct[{\n  'a' => String,\n  'b' => Integer\n}]")).to eq('Struct[…]')
    expect(described_class.abbreviate("[1,\n 2]")).to eq('[…]')
    expect(described_class.abbreviate('Enum[a, b')).to eq('Enum[a, b')
    expect(described_class.abbreviate('Integer[0, 65535]')).to eq('Integer[0, 65535]')
    expect(described_class.abbreviate('Sensitive[String[1]]')).to eq('Sensitive[String[1]]')
    expect(described_class.abbreviate('Pattern[/^(([a-zA-Z]:[\\\\\\/])|x)/]')).to eq('Pattern[…]')
    expect(described_class.abbreviate('Stdlib::Compat::Integer[1]')).to eq('Stdlib::Compat::Integer[1]')
    expect(described_class.abbreviate('x' * 80)).to eq("#{'x' * 69}…")
  end

  it 'reads a parameter as its declaration, signatures as parameter lists, and marks alike sides apart' do
    added = change('classes', 'foo', %w[params x], 'changed', nil, { 'type' => 'Boolean', 'default' => '$is_slave' })
    expect(described_class.detail(added)).to eq('Boolean $x = $is_slave')
    rest = change('classes', 'foo', %w[params rest], 'changed', { 'type' => 'Array[String]', 'captures_rest' => true }, nil)
    expect(described_class.detail(rest)).to eq('was Array[…] *$rest')
    sigs = change('functions', 'f', %w[signatures], 'changed',
                  [{ 'params' => ['text'], 'type' => 'Callable[String]' }],
                  [{ 'params' => %w[text times], 'type' => 'Callable[String, Integer, 1, 2]', 'return_type' => 'String', 'block' => 'blk' }])
    expect(described_class.detail(sigs)).to eq('(text) -> (text, times, &blk) -> String')
    alike = change('classes', 'foo', %w[params a default], 'changed', "{\n 'a' => 1 }", "{\n 'a' => 2 }")
    expect(described_class.detail(alike)).to eq("{ 'a' => 1 } -> { 'a' => 2 }")
    folded = change('type_aliases', 'T', %w[type], 'changed', 'Variant[String, Integer]', 'Variant[String, Float]')
    expect(described_class.detail(folded)).to eq('Variant[…¹] -> Variant[…²]')
    expect(described_class.block(sigs)).to eq(['function f: changed signatures', '  - (text)', '  + (text, times, &blk) -> String'])
  end

  it 'splits an item into kind, namespace, and leaf' do
    expect(described_class.item_parts(change('classes', 'a::b', %w[params p], 'changed', nil, {}))).to eq(['class', 'a::b::', 'p'])
    expect(described_class.item_parts(change('types', 't', %w[params p], 'changed', nil, {}))).to eq(['type', 't ', 'p'])
    expect(described_class.item_parts(change('functions', 'stdlib::shout', [], 'added', nil, {}))).to eq(['function', 'stdlib::', 'shout'])
    expect(described_class.item_parts(change('facts', 'fips', [], 'added', nil, {}))).to eq(['fact', '', 'fips'])
    expect(described_class.item_parts(change('metadata', 'puppet', %w[requirements], 'changed', 'a', 'b'))).to eq(['requirement', '', 'puppet'])
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
