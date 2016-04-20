class LinodeDriver

  PROVIDER='Linode'
  PROVIDER_ID = 90
  CHEF_PROVIDER='linode'
  MAXJOBS = 1
  LOGIN_AS = 'root'

  def self.get_active location, all, &block
    servers = `bundle exec knife #{CHEF_PROVIDER} server list`
    srv = servers.split "\n"
    srv.shift  
    srv.each do |s|
      line = s.split ' '
      id = line[0]
      name = line[1]
      ips = line[2].split(',')  
      if ips[0].start_with? '192.168.'
        ip = ips[1]
      else
        ip = ips[0]
      end
      state = line[3]
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
    image = flavor['imageid']
    image = '124' if image.blank?
    if flavor['flavor'].blank?
      puts "must specify flavor"
      return nil
    end
    if flavor['login_as'].blank?
      puts "must specify login_as"
      return nil
    end
    scriptln = "yes|bundle exec knife #{CHEF_PROVIDER} server create -r '#{roles}' -L '#{name}' -N '#{name}' -I '#{image}' -f '#{flavor['flavor']}' --distro chef-full -x '#{flavor['login_as']}' -D '#{location}' #{flavor['additional']} 2>&1"
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
    "yes|bundle exec knife #{CHEF_PROVIDER} server delete #{id} --purge"
  end

end
