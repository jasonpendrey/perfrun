class GoogleDriver
  PROVIDER='Google Compute Engine'
  CHEF_PROVIDER='google'
  MAXJOBS = 2
  PROVIDER_ID = 920  
  LOGIN_AS='ubuntu'

  # @override
  def self.fullinstname instname, instloc
    instname+'-'+instloc.gsub(' ', '-')
  end  

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

  def self.create_server name, instance, location, login_as, ident
    roles = ""
    image = 'ubuntu-1410-utopic-v20150318c'
    system "yes|bundle exec knife google disk delete #{name} -Z #{location} 2>/dev/null; sleep 30 || true"
    return `yes|bundle exec knife google server create #{name} -r "#{roles}" -N #{name} -I #{image} -m "#{instance}" -V -Z "#{location}" -x '#{login_as}' -i '#{ident}' 2>&1`
  end

  def self.delete_server s, id, location, diskuuid=nil
    "yes|bundle exec knife #{CHEF_PROVIDER} server delete -N #{s}  #{id} -Z #{location} --purge; sleep 30; yes|bundle exec knife #{CHEF_PROVIDER} disk delete #{id} -Z #{location}"
  end

end
