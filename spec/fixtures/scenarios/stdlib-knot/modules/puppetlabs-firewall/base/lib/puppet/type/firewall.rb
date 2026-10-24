Puppet::Type.newtype(:firewall) do
  ensurable
  newparam(:name, namevar: true)
  newparam(:action)
end
