class SoftlayerDriver
  PROVIDER='Softlayer'
  CHEF_PROVIDER='softlayer'
  MAXJOBS = 2
  PROVIDER_ID = 574
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
      name = line[0]
      ip = line[2]
      state = line[4]
      if state == 'Running' or all
        yield id, name, ip, state
      end
    end
  end	     

  def self.create_server name, instance, location, login_as, ident
    roles = ""
    # 14.04
    image = '6b7df4f0-cfed-4550-ae0b-a48944e1792a'
    keys = '229075'
    return `yes|bundle exec knife softlayer server create --hostname #{name} --domain burstorm.com --datacenter "#{location}" -r "#{roles}" -N #{name} --image-id #{image} #{instance} -i #{ident} --ssh-keys #{keys}  2>&1`
  end

  def self.delete_server s, id, location, diskuuid=nil
    "echo 'delete #{id}/#{location}'; yes|bundle exec knife #{CHEF_PROVIDER} server destroy -N #{id}"
  end
end
