class HostDriver < Provider
  CHEF_PROVIDER = "host"
  MAXJOBS = 6
  LOGIN_AS = 'root'

  # @override
  def self.get_active location, all, &block
    # XXX this is something of a hack since there isn't a List for specified hosts
    $objs.each do |obj|
      driver = obj['provider']['cloud_driver'] || 'host'
      obj['compute_scopes'].each do |scope|
        flavor = scope['flavor']
        next if flavor.nil?
        driver = flavor['provider'] if flavor['provider']
        next if driver != 'host'
        name = fullinstname scope, location
        next if flavor['fqdn'].nil? or flavor['fqdn'].empty?
        yield scope['details'], name, flavor['fqdn'], 'active'
      end
    end
  end

  def self.fullinstname scope, locflavor
    scopename = scope['details'] || 'compute-'+scope['id']
    scopename.gsub(/[ \/]/, '-')
  end

  def self.create_server name, scope, flavor, location, provtags
    # nothing to do
    return {id: flavor['fqdn'], ip: flavor['fqdn']}
  end

  # @override
  def self.delete_server name, id, location, flavor
    # nothing to do
    return "#{name} done"
  end

  # @override
  def flavordefaults scope
    flavor = scope['flavor']
    return nil if flavor.nil?
    flavor['login_as'] = LOGIN_AS if flavor['login_as'].blank?
    unless flavor['keyfile'].blank?
      if ! flavor['keyfile'].include?('/') and ! flavor['keyfile'].include?('..')
        flavor['keyfile'] = "#{Dir.pwd}/config/#{flavor['keyfile']}"
      end
    else
      flavor['keyfile'] = "#{Dir.pwd}/config/servers.pem"
    end
    flavor
  end


end
