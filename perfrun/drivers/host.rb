class HostDriver

  CHEF_PROVIDER = "host"
  MAXJOBS = 6
  LOGIN_AS = 'root'

  def initialize 
    @maxjobs = MAXJOBS
  end


  # @override
  def self.get_active location, all, &block
    # XXX this is something of a hack since there isn't a List for specified hosts
    $objs.each do |obj|
      next if obj['provider']['cloud_driver'] != 'host'
      obj['compute_scopes'].each do |scope|
        name = scope['details']+'/'+location      
        flavor = scope['flavor']
        next if flavor.nil?
        next if flavor['fqdn'].nil? or flavor['fqdn'].empty?
        yield scope['details'], name, flavor['fqdn'], 'active'
      end
    end
  end

  def self.create_server name, flavor, location, provtags
    # nothing to do
    return 'true'
  end

  # @override
  def self.delete_server name, id, location, diskuuid=nil
    # nothing to do
    return 'true'
  end

end
