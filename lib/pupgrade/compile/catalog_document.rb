module Pupgrade
  module Compile
    # The catalog as a file: Puppet's own data hash (the shape PuppetDB
    # stores) with everything that varies between runs removed or put in a
    # fixed order, so two compiles of the same code differ only where the
    # catalogs do.
    module CatalogDocument
      module_function

      # @param catalog [Puppet::Resource::Catalog]
      # @param version [String, Integer] recorded as the catalog's version in
      #   place of the compile time
      # @return [Hash] string-keyed, keys sorted at every level
      def build(catalog, version:)
        data = catalog.to_data_hash
        data['version'] = version
        data.delete('catalog_uuid')
        data['resources'] = data['resources'].sort_by { |r| [r['type'].to_s, r['title'].to_s] }.map { |r| resource(r) }
        data['edges']     = data['edges'].sort_by { |e| [e['source'].to_s, e['target'].to_s] }
        data['classes']   = data['classes'].sort
        data['tags']      = data['tags'].sort
        sort_keys(data)
      end

      def resource(r)
        r = r.dup
        r['tags'] = r['tags'].sort if r['tags'].is_a?(Array)
        r
      end

      # Hash keys sorted at every level; arrays keep their order.
      def sort_keys(value)
        case value
        when Hash  then value.sort_by { |k, _| k.to_s }.to_h { |k, v| [k, sort_keys(v)] }
        when Array then value.map { |v| sort_keys(v) }
        else value
        end
      end
    end
  end
end
