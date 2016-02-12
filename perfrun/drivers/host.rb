class HostDriver

  MAXJOBS = 6

  def initialize 
    @maxjobs = MAXJOBS
  end


  # @override
  def get_active location, all, &block
    $instances.each do |host|
      name = host[:instname]+'/'+location      
      if host[:fqdn].nil? or host[:fqdn].empty?
        puts "skipping #{name} because no fqdn to login"
        next
      end
      yield host[:instname], name, host[:fqdn], 'active'
    end
  end

  # @override
  def delete_server name, id, location, diskuuid=nil
    # nothing to do
    return 'true'
  end

end
