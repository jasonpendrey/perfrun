
class GoogleDriver < Provider
  PROVIDER='Google Compute Engine'
  CHEF_PROVIDER='google'
  MAXJOBS = 1
  PROVIDER_ID = 920  
  LOGIN_AS = 'ubuntu'
  DEFIMAGE='ubuntu-1410-utopic-v20150318c'

  @verbose = 0
  @keypath = "config"

  def self.get_active location, all, &block
    s = get_auth location
    s.servers.each do |server|
      if server.state == 'running' or all      
        yield server.id, server.tags['Name'], server.public_ip_address, server.state
      end
    end
  end	     

  def self.create_server name, flavor, loc, provtags
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
    server = self._create_server name, flavor, loc, image
    if server.nil?
      puts "can't create #{name}: #{server}"
      return nil
    end
    puts "server=#{server.inspect}"
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
    image = 'ubuntu-1410-utopic-v20150318c' if image.blank?
    rv = `yes|bundle exec knife #{CHEF_PROVIDER} disk delete #{name} -Z #{location} 2>&1`
    sleep 60 if ! rv.start_with? 'ERROR:'
    scriptln = "yes|bundle exec knife #{CHEF_PROVIDER} server create '#{name}' -r '#{roles}' -N '#{name}' -I '#{image}' -m '#{flavor['flavor']}' -V -Z '#{location}' -x '#{flavor['login_as']}' -i '#{flavor['keyfile']}' #{flavor['additional']} 2>&1"
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

  def self._create_server name, flavor, loc, image
    s = get_auth loc
    disk = s.disks.create(:name => name, :size_gb => 10, :zone_name => loc, :source_image => image)
    puts disk.inspect
    disk.wait_for { disk.ready? }
    puts "disk ready."
    pubkey = `ssh-keygen -y -f #{flavor['keyfile']}`
    f = Tempfile.new
    f.write(pubkey)
    f.close
    server = s.servers.create(
                              :name => name,
                              :disks => [disk],
                              :machine_type => flavor['flavor'],
                              :private_key_path => flavor['keyfile'],
                              :public_key_path => f.path,
                              :zone_name => loc,
                              #                      :user => ENV["USER"],
                              :tags => [],
                              #                      :service_accounts => %w(sql-admin bigquery https://www.googleapis.com/auth/compute)
                      )
    server
  end

end
