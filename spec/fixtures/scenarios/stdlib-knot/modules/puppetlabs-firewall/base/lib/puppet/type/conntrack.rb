Puppet::Type.newtype(:conntrack) do
  newparam(:name, namevar: true)
end
