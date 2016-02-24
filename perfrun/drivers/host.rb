class HostDriver

  CHEF_PROVIDER = "host"
  LOGIN_AS = "root"
  MAXJOBS = 6

  def initialize 
    @maxjobs = MAXJOBS
  end


  # @override
  def self.get_active location, all, &block
    $perfrun_table.each do |obj|
      obj['instances'].each do |host|        
        name = host['instname']+'/'+location      
        next if host['provider'] != 'host'
        next if host['fqdn'].nil? or host['fqdn'].empty?
        yield host['instname'], name, host['fqdn'], 'active'
      end
    end
  end

  def self.create_server name, instance, location, login_as, ident
    # nothing to do
    return 'true'
  end

  # @override
  def self.delete_server name, id, location, diskuuid=nil
    # nothing to do
    return 'true'
  end

end
