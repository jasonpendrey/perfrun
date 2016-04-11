class GoogleDriver
  PROVIDER='Google Compute Engine'
  CHEF_PROVIDER='google'
  MAXJOBS = 1
  PROVIDER_ID = 920  
  LOGIN_AS = 'ubuntu'

  def self.get_active location, all, &block
    servers = `bundle exec knife #{CHEF_PROVIDER} server list -Z #{location}`
    srv = servers.split "\n"
    srv.shift  
    srv.each do |s|
      line = s.split ' '
      id = line[0]
      name = line[0]
      ip = line[2]
      state = line[6]
      if state == 'running' or all
        yield id, name, ip, state
      end
    end
  end	     

  def self.create_server name, flavor, location, provtags
    roles = provtags.join ','
    image = flavor['imageid'] || 'ubuntu-1410-utopic-v20150318c'
    rv = `yes|bundle exec knife #{CHEF_PROVIDER} disk delete #{name} -Z #{location} 2>&1`
    sleep 60 if ! rv.start_with? 'ERROR:'
    return `yes|bundle exec knife #{CHEF_PROVIDER} server create '#{name}' -r "#{roles}" -N '#{name}' -I '#{image}' -m "#{flavor['flavor']}" -V -Z "#{location}" -x '#{flavor['login_as']}' -i '#{flavor['keyfile']}' #{flavor['additional']} 2>&1`
  end

  def self.delete_server s, id, location, diskuuid=nil
    "yes|bundle exec knife #{CHEF_PROVIDER} server delete -N #{s}  #{id} -Z #{location} --purge; sleep 60; yes|bundle exec knife #{CHEF_PROVIDER} disk delete #{id} -Z #{location}"
  end

end
