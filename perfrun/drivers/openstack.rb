require 'fog'
require 'fog/openstack'

class OpenstackDriver < Provider
  PROVIDER='Openstack'
  LOG_PROVIDER='openstack'
  MAXJOBS = 1
  LOGIN_AS = 'ubuntu'


  def self.get_active loc, all, &block      
    s = get_auth loc
    s.servers.each do |server|
      state = server.status
      id = server.id
      ip = server.accessIPv4
      name = server.name
      if state == 'ACTIVE' or all
        yield id, name, ip, state
      end      
    end
    get_image loc
  end

  def self.create_server name, scope, flavor, loc
    if flavor['keyname'].blank?
      puts "must specify keyname"
      return nil
    end
    image = flavor['imageid']
    image = get_image loc if image.blank?
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
    rv[:ip] = server.accessIPv4
    rv[:ipv6] = server.accessIPv6
    rv
  end

  def self.get_auth loc
    return @auth if @auth
    keys = get_keys loc
    @auth = Fog::Compute.new({:provider => 'Openstack'}.merge keys)
  end

  def self.get_keys loc
    super({:openstack_username => nil, :openstack_api_key => nil, :openstack_auth_url => nil, :openstack_project_name => nil, :openstack_domain_id => nil}, loc)
  end

  def self._create_server name, scope, instance, loc, keyname, image, createvol=false
    s = get_auth loc
    sparams = { 
      :name => name, 
      :image_ref => image,  
      :key_name => keyname
    }
    if instance.blank?
      # XXX does this work for openstack?
      storage = scope['storage'] || 20
      storage = 20 if storage < 20
      cpu = scope['cores'] || 1
      ram = (scope['ram'].to_f) * 1024
      sparams[:cpu] = cpu
      sparams[:ram] = ram
    else
      sparams[:flavor_ref] = instance
    end
    server = s.servers.create(sparams)
    server
  end

  def self._delete_server id, loc
    begin
      s = get_auth loc
      server = s.servers.get(id)    
      if server
        if server.respond_to? :destroy
          server.destroy 
        else
          server.delete
        end
      end
    rescue Exception => e
      log "e=#{e.message}"
    end
  end

  # XXX the image fetching needs rationalized
  def self.get_image loc
    if @ubuntuimage and @fetchtime+3600 > Time.now
      return @ubuntuimage 
    end
    @fetchtime = Time.now
    s = get_auth loc
    imgs = []
    s.images.each do |img|
      puts img.inspect
      next unless img.name.include? 'ubuntu-14.04'
      imgs.push img.name
    end
    imgs.sort!
    return @ubuntuimage = imgs.last
  end

  # @override
  def self.flavordefaults scope
    super scope, true
  end

end
