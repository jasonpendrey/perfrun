class HostDriver < Provider
  CHEF_PROVIDER = "host"
  MAXJOBS = 6
  LOGIN_AS = 'root'

  # @override
  def self.get_active location, all, &block
    # XXX this is something of a hack since there isn't a List for specified hosts
    $objs.each do |obj|
      driver = obj['provider']['cloud_driver'] || 'host'
      next if driver != 'host'
      obj['compute_scopes'].each do |scope|
        name = fullinstname scope, location
        flavor = scope['flavor']
        next if flavor.nil?
        next if flavor['fqdn'].nil? or flavor['fqdn'].empty?
        yield scope['details'], name, flavor['fqdn'], 'active'
      end
    end
  end

  def self.fullinstname scope, locflavor
    scopename = scope['details'] || 'compute-'+scope['id']
    rv = scopename+'-'+(locflavor || 'no-location')
    rv.gsub(/[ \/]/, '-')
  end

  def self.create_server name, scope, flavor, location, provtags
    # nothing to do
    return {id:name, ip:name}
  end

  # @override
  def self.delete_server name, id, location, flavor
    # nothing to do
    return "#{name} done"
  end

end
