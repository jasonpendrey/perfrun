require 'fog'
require 'fog/azure'
require 'xmlsimple'

class AzureDriver < Provider
  PROVIDER = 'Microsoft Azure'
  CHEF_PROVIDER = 'azure'
  MAXJOBS = 1
  PROVIDER_ID = 92
  LOGIN_AS = 'ubuntu'

  @verbose = 0
  @keypath = "config"

  def self.get_active location, all, &block
    s = get_auth location
    servers = s.servers.each do |server|
      if server.state == 'ready' or all      
        yield server.id, server.name, server.public_ip_address, server.state
      end
    end
  end	     

  def self.create_server name, flavor, loc, provtags
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
    image = flavor['imageid']
    image = 'b39f27a8b8c64d52b05eac6a62ebad85__Ubuntu-14_04_2_LTS-amd64-server-20150309-en-us-30GB' if image.blank?
    server = self._create_server name, flavor['flavor'], loc, flavor['keyname'], image, false
    if server.nil?
      puts "can't create #{name}: #{server}"
      return nil
    end
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
    # 14.04
    image = flavor['imageid']
    image = 'b39f27a8b8c64d52b05eac6a62ebad85__Ubuntu-14_04_2_LTS-amd64-server-20150309-en-us-30GB' if image.blank?
    dns = name.gsub('_', '-')
    scriptln = "yes|bundle exec knife #{CHEF_PROVIDER} server create -r '#{roles}' --azure-vm-name '#{name}' --azure-dns-name 'perfrun-#{dns}' -N '#{dns}' -I '#{image}' --azure-vm-size '#{flavor['flavor']}' -V -m '#{location}' --ssh-user '#{flavor['login_as']}' --ssh-port 22 --identity-file '#{flavor['keyfile']}'  #{flavor['additional']} 2>&1"
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
    management_cert = OpenSSL::PKCS12.new(Base64.decode64(keys[:apiKey]))
    f = Tempfile.new ''
    f.write management_cert.certificate.to_pem + management_cert.key.to_pem
    f.close
    opts = {:provider => 'Azure', :azure_sub_id => keys[:username], :azure_pem => f.path}
    puts opts.inspect
    @auth = Fog::Compute.new(opts)
    puts "got here"
  end

  # XXX there's probably a better way to read knife.rb...
  def self.get_keys loc
    ukey = "knife[:azure_publish_settings_file]"
    rv = {}
    File.open(self.config loc).each do |line|
      # kill comments
      idx = line.index '#'
      unless idx.nil?
        line = line[0..idx-1]
      end
      if line.start_with? ukey
        l = line.split '='
        rv[:xml] = l[1].strip[1..-2]
      end
    end
    data = File.read 'config/'+rv[:xml]
    xml = XmlSimple.xml_in data
    rv[:username] = xml['PublishProfile'][0]['Subscription'][0]['Id']
    rv[:apiKey] = xml['PublishProfile'][0]['Subscription'][0]['ManagementCertificate']
    rv[:url] = xml['PublishProfile'][0]['Subscription'][0]['ServiceManagementUrl']
    #puts rv.inspect
    rv
  end

  def self._create_server name, instance, loc, pass, image, createvol=false
    s = get_auth loc
    server = s.servers.create(:vm_name => name, :image => image, :location => loc, :vm_size => instance, :password => gen_pass)
    server
  end

end
