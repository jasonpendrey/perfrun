class DigitalOceanDriver

  PROVIDER='Digital Ocean'
  CHEF_PROVIDER='digital_ocean'
  MAXJOBS = 1
  PROVIDER_ID = 110
  LOGIN_AS = 'root'

  def self.get_active location, all, &block
    servers = `bundle exec knife #{CHEF_PROVIDER} droplet list`
    srv = servers.split "\n"
    srv.shift      
    srv.each do |s|
      # Note: this is sort of a big greasy hack to use 2 spaces to split so that the region strings don't screw stuff up
      line = s.split '  '
      nline = []
      line.each do |l|
        nline.push l if ! l.strip.empty?
      end
      line = nline
      id = line[0].strip
      name = line[1].strip
      state = line.last.strip
      ip = line[4].strip
      if state == 'active' or all
        yield id, name, ip, state
      end
    end
  end	     

  def self.create_server name, flavor, location, provtags
    roles = provtags.join ','
    image = flavor['imageid'] || get_image(location)
    if image.nil?
      puts "can't find image for location #{location}"
      exit 0
    end
    cmd = "yes|bundle exec knife #{CHEF_PROVIDER} droplet create --server-name '#{name}' --image '#{image}' --location '#{location}' --size '#{flavor['flavor']}'  --bootstrap --ssh-keys '#{flavor['keyname']}' -i '#{flavor['keyfile']}' -x '#{flavor['login_as']}' --run-list \"#{roles}\" #{flavor['additional']} 2>&1"
    rv = `#{cmd}`
    rv
  end

  def self.delete_server s, id, location, diskuuid=nil
    "yes|bundle exec knife #{CHEF_PROVIDER} droplet destroy -S #{id}"
  end

  def self.get_image location
    if @ubuntuimage and @fetchtime+3600 > Time.now
      return @ubuntuimage 
    end
    @fetchtime = Time.now
    `bundle exec knife #{CHEF_PROVIDER} image list -P`.split("\n").each do |line|
      next unless line.include? 'ubuntu-14-04-x64'
      return @ubuntuimage = line.split(" ")[0]      
    end
    return nil
  end

end
