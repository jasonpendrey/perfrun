require 'fog'

class DigitalOceanDriver < Provider
  PROVIDER='Digital Ocean'
  LOG_PROVIDER='digital_ocean'
  MAXJOBS = 1
  PROVIDER_ID = 110
  LOGIN_AS = 'root'

  def self.get_active location, all, &block
    s = get_auth location
    servers = s.servers.each do |server|
      next if server.attributes[:region]['slug'] != location
      if server.status == 'active' or all      
        yield server.id, server.name, server.public_ip_address, server.status
      end
    end
  end	     

  def self.create_server name, scope, flavor, loc
    image = flavor['imageid']
    image = get_image(loc) if image.blank?
    if image.blank?
      puts "can't find image for location #{loc}"
      return nil
    end
    if flavor['keyname'].blank?
      puts "must specify keyname"
      return nil
    end
    server = self._create_server name, flavor['flavor'], loc, flavor['keyname'], image, false
    if server.nil?
      log "can't create #{name}: #{server}"
      return nil
    end
    rv = {}
    server.wait_for { 
      server.ready? 
    }
    rv[:id] = server.id
    rv[:ip] = server.public_ip_address
    sleep 10
    rv
  end

  def self.get_auth loc
    return @auth if @auth
    keys = get_keys loc
    @auth = Fog::Compute.new({:provider => 'DigitalOcean', :version => 'V2'}.merge keys)
  end

  def self.get_keys loc
    super({:digitalocean_token =>nil}, loc)
  end

  def self._create_server name, instance, loc, keyname, image, createvol=false
    s = get_auth loc
    server = s.servers.create(:name => name, :image => image, :size => instance, :region  => loc, ssh_keys: [keyname])
    server
  end

  def self.get_image loc
    return @ubuntuimage = 'ubuntu-14-04-x64'
=begin
    if @ubuntuimage and @fetchtime+3600 > Time.now
      return @ubuntuimage 
    end
    @fetchtime = Time.now
    s = get_auth loc
    s.images.each do |img|
      next unless img.slug == 'ubuntu-14-04-x64'
      return @ubuntuimage = img.slug
    end
    return nil
=end
  end

end
