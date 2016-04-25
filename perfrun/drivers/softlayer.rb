class SoftlayerDriver < Provider
  PROVIDER='Softlayer'
  CHEF_PROVIDER='softlayer'
  MAXJOBS = 1
  PROVIDER_ID = 574
  LOGIN_AS = 'root'

  @verbose = 0
  @keypath = "config"

  def self.get_active location, all, &block
    s = get_auth location
    servers = s.servers.each do |server|
      if server.state == 'Running' or all      
        yield server.id, server.name, server.public_ip_address, server.state
      end
    end
  end	     

  def self.create_server name, flavor, loc, provtags
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
    image = '6b7df4f0-cfed-4550-ae0b-a48944e1792a' if image.blank?
    server = self._create_server name, flavor['flavor'], loc, flavor['keyname'], image, false
    if server.nil?
      puts "can't create #{name}: #{server}"
      return nil
    end
    id = server.id
    server.wait_for { 
      server.ready? 
    }
    ip = server.public_ip_address
    rv = ""
    if flavor['provisioning'] == 'chef'
      sleep 1
      rv += ChefDriver.chef_bootstrap ip, name, provtags, flavor, loc, nil, config(loc) 
    end
    rv
  end

  def self.create_server_old name, flavor, location, provtags
    roles = []
    provtags.each do |tag|
      roles.push 'role['+tag+']'
    end
    roles = roles.join ','
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
    # 14.04
    image = flavor['imageid']
    image = '6b7df4f0-cfed-4550-ae0b-a48944e1792a' if image.blank?
    scriptln = "yes|bundle exec knife #{CHEF_PROVIDER} server create --hostname '#{name}' --domain burstorm.com --datacenter '#{location}' -r '#{roles}' -N '#{name}' --image-id '#{image}' #{flavor['flavor']} -i '#{flavor['keyfile']}' --ssh-keys '#{flavor['keyname']}' -x '#{flavor['login_as']}' #{flavor['additional']} 2>&1"
    puts "#{scriptln}" if @verbose > 0
    rv = ''
    IO.popen scriptln do |fd|
      fd.each do |line|
        puts line if @verbose > 0
        STDOUT.flush
        rv += line
      end
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

  def self._create_server name, instance, loc, keyname, image, createvol=false
    s = get_auth loc
    k = s.key_pairs.get(keyname)
    sparams = { :name => name, 
      :image_id => image,  
      :datacenter => loc,
      :key_pairs => [k]
    }
    params = instance.split ' '
    if params.length > 0
      storage = 50
      cpu = 2
      ram = 2048
      sparams[:cpu] = cpu
      sparams[:ram] = ram
#      sparams[:disk] = {'capacity' => storage }
    else
      sparams[:flavor_id] = instance
    end
    server = s.servers.create(sparams)
    server
  end

end
