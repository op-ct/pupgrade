Puppet::Functions.create_function(:'stdlib::shout') do
  dispatch(:shout) { param 'String', :text }
  def shout(text)
    text.upcase
  end
end
