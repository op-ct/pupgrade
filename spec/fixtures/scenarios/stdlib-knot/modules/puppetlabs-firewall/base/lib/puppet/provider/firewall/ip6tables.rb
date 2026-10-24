Puppet::Type.type(:firewall).provide(:ipv6, parent: :iptables, source: :iptables) do
  commands ip6tables: 'ip6tables'
end
