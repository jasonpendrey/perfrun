class AzureDriver
  PROVIDER = 'Microsoft Azure'
  CHEF_PROVIDER = 'azure'
  MAXJOBS = 1
  PROVIDER_ID = 92
  LOGIN_AS = 'ubuntu'

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

  def self.create_server name, flavor, location, provtags
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
    # 14.04
    image = flavor['imageid']
    image = 'b39f27a8b8c64d52b05eac6a62ebad85__Ubuntu-14_04_2_LTS-amd64-server-20150309-en-us-30GB' if image.blank?
    dns = name.gsub('_', '-')
    scriptln = "yes|bundle exec knife #{CHEF_PROVIDER} server create -r '#{roles}' --azure-vm-name '#{name}' --azure-dns-name 'perfrun-#{dns}' -N '#{dns}' -I '#{image}' --azure-vm-size '#{flavor['flavor']}' -V -m '#{location}' --ssh-user '#{flavor['login_as']}' --ssh-port 22 --identity-file '#{flavor['keyfile']}'  #{flavor['additional']} 2>&1"
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

  def self.delete_server name, id, location, diskuuid=nil
    dns = name.gsub('_', '-')
    "yes|bundle exec knife #{CHEF_PROVIDER} server delete -N #{dns}  #{id} --purge"
  end

end
