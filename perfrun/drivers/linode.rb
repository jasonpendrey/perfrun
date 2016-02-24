class LinodeDriver

  PROVIDER='Linode'
  PROVIDER_ID = 90
  CHEF_PROVIDER='linode'
  MAXJOBS = 1
  LOGIN_AS='root'

  # @override
  def self.fullinstname instname, instloc
    instname+'-'+instloc.gsub(' ', '-')
  end

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

  def self.create_server name, instance, location, login_as, ident
    roles = ""
    # the image corresponds to ubuntu 14.04, flavor is 2G
    image = 124
    return `yes|bundle exec knife linode server create -r "#{roles}" -L #{name} -N #{name} -I #{image} -f #{instance} --distro chef-full -x #{login_as} -D "#{location}" 2>&1`
  end

  def self.delete_server s, id, location, diskuuid=nil
    "yes|bundle exec knife #{CHEF_PROVIDER} server delete #{id} --purge"
  end

end
