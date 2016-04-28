require 'fog'

class DigitalOceanDriver < Provider
  PROVIDER='Digital Ocean'
  CHEF_PROVIDER='digital_ocean'
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

  def self.create_server name, scope, flavor, loc, provtags
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
    server = self._create_server name, flavor['flavor'], loc, flavor['keyname'], image, false
    if server.nil?
      puts "can't create #{name}: #{server}"
      return nil
    end
    rv = {}
    server.wait_for { 
      server.ready? 
    }
    rv[:id] = server.id
    rv[:ip] = server.public_ip_address
    if flavor['provisioning'] == 'chef'
      sleep 1
      begin
        rv[:provisioning_out] = ChefDriver.bootstrap rv[:ip], name, provtags, flavor, loc, nil, config(loc) 
      rescue Exception => e
        puts "e=#{e.message}"
      end
    end
    rv
  end

  def self.get_auth loc
    return @auth if @auth
    keys = get_keys loc
    @auth = Fog::Compute.new(:provider => 'DigitalOcean', :digitalocean_token => keys[:apiKey], :version => 'V2')
  end

  # XXX there's probably a better way to read knife.rb...
  def self.get_keys loc
    akey = "knife[:digital_ocean_access_token]"
    rv = {}
    File.open(self.config loc).each do |line|
      # kill comments
      idx = line.index '#'
      unless idx.nil?
        line = line[0..idx-1]
      end
      if line.start_with? akey
        l = line.split '='
        rv[:apiKey] = l[1].strip[1..-2]
      end
    end
    rv
  end

  def self._create_server name, instance, loc, keyname, image, createvol=false
    s = get_auth loc
    server = s.servers.create(:name => name, :image => image, :size => instance, :region  => loc, ssh_keys: [keyname])
    server
  end

  def self.get_image loc
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
  end

end
