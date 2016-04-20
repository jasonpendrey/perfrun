class SoftlayerDriver
  PROVIDER='Softlayer'
  CHEF_PROVIDER='softlayer'
  MAXJOBS = 1
  PROVIDER_ID = 574
  LOGIN_AS = 'root'

  def self.get_active location, all, &block
    servers = `bundle exec knife #{CHEF_PROVIDER} server list`
    srv = servers.split "\n"
    srv.shift  
    srv.each do |s|
      line = s.split ' '
      id = line[0]
      name = line[0]
      ip = line[2]
      state = line[4]
      if state == 'Running' or all
        yield id, name, ip, state
      end
    end
  end	     

  def self.create_server name, flavor, location, provtags
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
    puts "#{scriptln}"
    rv = ''
    IO.popen scriptln do |fd|
      fd.each do |line|
        puts line
        STDOUT.flush
        rv += line
      end
    end
    rv
  end

  def self.delete_server s, id, location, diskuuid=nil
    "echo 'delete #{id}/#{location}'; yes|bundle exec knife #{CHEF_PROVIDER} server destroy -N #{id}"
  end
end
