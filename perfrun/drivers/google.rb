require 'fog'

class GoogleDriver < Provider
  PROVIDER='Google Compute Engine'
  CHEF_PROVIDER='google'
  MAXJOBS = 2
  PROVIDER_ID = 920  
  LOGIN_AS = 'ubuntu'
  DEFIMAGE='ubuntu-1404-trusty-v20160509a'

  def self.get_active location, all, &block
    s = get_auth location
    s.servers.each do |server|
      # comes in as a url... grumble
      zone = server.zone.split('/').last
      next if zone and zone != location
      if server.state == 'RUNNING' or all      
        yield server.id, server.name, server.public_ip_address, server.state
      end
    end
  end	     

  def self.create_server name, scope, flavor, loc
    image = flavor['imageid']
    #image = DEFIMAGE if image.blank?
    image = get_image loc if image.blank?
    server = self._create_server name, scope, flavor, loc, image
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
    @auth = Fog::Compute.new(:provider => 'Google', google_project: keys[:username], google_json_key_location: keys[:apiKey] )
  end

  # XXX there's probably a better way to read knife.rb...
  def self.get_keys loc
    ukey = "knife[:google_project]"
    akey = "knife[:google_json_key_location]"
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
    end
    rv
  end

  def self._create_server name, scope, flavor, loc, image
    s = get_auth loc
    storage = scope['storage'] || 20
    storage = 20 if storage < 20
    if ! (disk = fetch_disk(name, loc))
      disk = s.disks.create(:name => name, :size_gb => storage, :zone_name => loc, :source_image => image)
    end
    disk.wait_for { disk.ready? }
    pubkey = `ssh-keygen -y -f #{flavor['keyfile']}`
    f = Tempfile.new 'goog'
    f.write(pubkey)
    f.close
    server = s.servers.create(
                              :name => name,
                              :disks => [disk],
                              :machine_type => flavor['flavor'],
                              :private_key_path => flavor['keyfile'],
                              :public_key_path => f.path,
                              :zone_name => loc,
                              :user => flavor['login_as'],
                              :tags => []
                      )
    server
  end


  # @override: google does .get as name rather than id... grr
  def self.fetch_server name, loc
    s = get_auth loc
    s.servers.get name
  end

  def self.fetch_disk name, loc
    s = get_auth loc
    s.disks.get name
  end

  def self.delete_server name, id, loc, flavor
    self._delete_server id, name, loc
    nil
  end

  def self._delete_server id, name, loc
    begin
      server = self.fetch_server name, loc
      if server
        server.destroy 
      else
        log "can't find server..."        
      end
      while s = self.fetch_server(name, loc)
        break if s.state == 'TERMINATED'
        sleep 1
        log "#{name}: #{s.state}"
      end
      while disk = self.fetch_disk(name, loc)
        sleep 1
        next if disk.status == 'FAILED'
        begin
          disk.destroy 
        rescue Exception => e
          # gross, but the exception is just a generic fog error...
          # XXX maybe there is a way to determine if it's inuse otherwise...
          next if e.message.include? "is already being used by"
          log "e=#{e.message} #{e} #{e.class}"
        end
        break
      end
    rescue Exception => e
      log "e=#{e.message}"
    end
  end

  def self.get_image loc
    if @ubuntuimage and @fetchtime+3600 > Time.now
      return @ubuntuimage 
    end
    @fetchtime = Time.now
    s = get_auth loc
    imgs = []
    s.images.each do |img|
      next unless img.name.start_with? 'ubuntu-1404'
      imgs.push img.name
    end
    imgs.sort!
    return @ubuntuimage = imgs.last
  end

end
