class AzureDriver
  PROVIDER = 'Microsoft Azure'
  CHEF_PROVIDER = 'azure'
  MAXJOBS = 2
  PROVIDER_ID = 92
  LOGIN_AS='ubuntu'

  # @override
  def self.fullinstname instname, instloc
    instname+'-'+instloc.gsub(' ', '-')
  end
  
  def self.get_active location, all, &block
    servers = `bundle exec knife #{CHEF_PROVIDER} server list`
    srv = servers.split "\n"
    while srv[0] == '.'
      srv.shift
    end
    srv.shift  
    srv.each do |s|
      line = s.split ' '
      id = line[1]
      name = line[1]
      ip = line[3]
      state = line[2]
      if state == 'ready' or all
        yield id, name, ip, state
      end
    end
  end	     

  def self.create_server name, instance, location, login_as, ident
    roles = ""
    # 14.04
    image = 'b39f27a8b8c64d52b05eac6a62ebad85__Ubuntu-14_04_2_LTS-amd64-server-20150309-en-us-30GB'
    return `yes|bundle exec knife azure server create -r "#{roles}" --azure-vm-name #{name} --azure-dns-name "bb#{name}" -N #{name} -I #{image} --azure-vm-size "#{instance}" -V -m "#{location}" --ssh-user '#{login_as}' --ssh-port 22 --identity-file #{ident} 2>&1`
  end

  def self.delete_server s, id, location, diskuuid=nil
    "yes|bundle exec knife #{CHEF_PROVIDER} server delete -N #{s}  #{id} --purge"
  end

end
