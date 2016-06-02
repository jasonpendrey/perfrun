require 'fog'

class SoftlayerDriver < Provider
  PROVIDER='Softlayer'
  LOG_PROVIDER='softlayer'
  MAXJOBS = 1
  PROVIDER_ID = 574
  LOGIN_AS = 'root'
  DEFIMAGE = '02d88f3c-8adb-497d-8e76-c7d80a27ed57'

  def self.get_active location, all, &block
    s = get_auth location
    servers = {}
    s.servers.each do |server|
      next if servers[server.id]
      servers[server.id] = true
      next if server.attributes[:datacenter] and server.attributes[:datacenter][:name] != location
      if server.state == 'Running' or all      
        yield server.id, server.name, server.public_ip_address, server.state
      end
    end
  end	     

  def self.create_server name, scope, flavor, loc
    if flavor['keyname'].blank?
      puts "must specify keyname"
      return nil
    end
    image = flavor['imageid']
    image = DEFIMAGE if image.blank?
    server = self._create_server name, scope, flavor['flavor'], loc, flavor['keyname'], image, false
    if server.nil?
      puts "can't create #{name}: #{server}"
      return nil
    end
    server.wait_for { 
      server.ready? 
    }
    rv = {}
    server.reload
    rv[:id] = server.id
    rv[:ip] = server.public_ip_address
    # it seems that softlayer reboots or something like that right after initial spinup, so give some time before declaring it ready
    log "#{name} created... waiting out softlayer gratuitous reboot..."
    sleep 90    
    rv
  end

  def self.get_auth loc
    return @auth if @auth
    keys = get_keys loc
    @auth = Fog::Compute.new({:provider => 'Softlayer'}.merge keys)
  end

  def self.get_keys loc
    super({:softlayer_username => nil, :softlayer_api_key => nil, :softlayer_default_domain => nil}, loc)
  end

  def self._create_server name, scope, instance, loc, keyname, image, createvol=false
    s = get_auth loc
    k = s.key_pairs.get(keyname)
    sparams = { :name => name, 
      :image_id => image,  
      :datacenter => loc,
      :key_pairs => [k]
    }
    if instance.blank?
      storage = scope['storage'] || 20
      storage = 20 if storage < 20
      cpu = scope['cores'] || 1
      ram = (scope['ram'].to_f) * 1024
      sparams[:cpu] = cpu
      sparams[:ram] = ram
      #   needs os_code instead of an image_id... 
      #          sparams[:ephemeral_storage] = true
      #          sparams[:disk] = [{'device' => 0, 'diskImage' => {'capacity' => storage } }]
    else
      sparams[:flavor_id] = instance
    end
    server = s.servers.create(sparams)
    server
  end

  def self._delete_server id, loc
    begin
      s = get_auth loc
      server = s.servers.get(id)    
      if server
        return if server.state == 'Halted'
        if server.respond_to? :destroy
          server.destroy 
        else
          server.delete
        end
        server.wait_for { server.state == 'Halted' }
      end
    rescue Exception => e
      log "e=#{e.message}"
    end
  end

  # @override
  def self.flavordefaults scope
    super scope, true
  end

end
