class SoftlayerDriver < Provider
  PROVIDER='Softlayer'
  CHEF_PROVIDER='softlayer'
  MAXJOBS = 1
  PROVIDER_ID = 574
  LOGIN_AS = 'root'
  DEFIMAGE = '02d88f3c-8adb-497d-8e76-c7d80a27ed57'

  def self.get_active location, all, &block
    s = get_auth location
    servers = s.servers.each do |server|
      next if server.attributes[:datacenter] and server.attributes[:datacenter][:name] != location
      if server.state == 'Running' or all      
        yield server.id, server.name, server.public_ip_address, server.state
      end
    end
  end	     

  def self.create_server name, scope, flavor, loc, provtags
    if flavor['keyname'].blank?
      puts "must specify keyname"
      return nil
    end
    if flavor['flavor'].blank?
      puts "must specify flavor"
      return nil
    end
    if flavor['login_as'].blank?
      puts "must specify login_as"
      return nil
    end
    if flavor['keyfile'].blank?
      puts "must specify keyfile"
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
    rv[:id] = server.id
    rv[:ip] = server.public_ip_address
    if flavor['provisioning'] == 'chef'
      sleep 1
      rv[:provisioning_out] = ChefDriver.bootstrap rv[:ip], name, provtags, flavor, loc, nil, config(loc) 
    end
    rv
  end

  def self.get_auth loc
    return @auth if @auth
    keys = get_keys loc
    @auth = Fog::Compute.new(:provider => 'Softlayer', :softlayer_username => keys[:username], :softlayer_api_key => keys[:apiKey], :softlayer_default_domain => keys[:domain])
  end

  # XXX there's probably a better way to read knife.rb...
  def self.get_keys loc
    ukey = "knife[:softlayer_username]"
    akey = "knife[:softlayer_api_key]"
    dkey = "knife[:softlayer_default_domain]"
    rv = {}
    File.open(self.config loc).each do |line|
      # kill comments
      idx = line.index '#'
      unless idx.nil?
        line = line[0..idx-1]
      end
      if line.start_with? ukey
        l = line.split '='
        rv[:username] = l[1].strip[1..-2]
      end
      if line.start_with? akey
        l = line.split '='
        rv[:apiKey] = l[1].strip[1..-2]
      end
      if line.start_with? dkey
        l = line.split '='
        rv[:domain] = l[1].strip[1..-2]
      end
    end
    rv
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
      end
    rescue Exception => e
      puts "server=#{server.inspect}"
      puts "e=#{e.message}"
    end
  end

end
