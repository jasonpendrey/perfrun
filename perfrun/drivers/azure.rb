require 'fog'
require 'fog/azure'
require 'azure/core'
require 'xmlsimple'

class AzureDriver < Provider
  PROVIDER = 'Microsoft Azure'
  CHEF_PROVIDER = 'azure'
  MAXJOBS = 1
  PROVIDER_ID = 92
  LOGIN_AS = 'ubuntu'
  DEFIMAGE = 'b39f27a8b8c64d52b05eac6a62ebad85__Ubuntu-14_04_2_LTS-amd64-server-20150309-en-us-30GB'

  def self.get_active location, all, &block
    s = get_auth location
    s.servers.each do |server|
      # XXX: fricking azure doesn't seem to have which datacetner it's located in... location doesn't return anything
      if server.state == 'Running' or all      
        yield server.vm_name, server.vm_name, server.public_ip_address, server.state
      end
    end
  end	     

  def self.create_server name, scope, flavor, loc
    image = flavor['imageid']
    image = DEFIMAGE if image.blank?
    server = self._create_server name, scope, flavor['flavor'], loc, flavor['keyfile'], image
    if server.nil?
      log "can't create #{name}: #{server}"
      return nil
    end
    # can't use wait_for because ms changed server.get to require two parameters which causes wait_for to puke
    nretry = 60
    while nretry >= 0 do 
      server = self.fetch_server server.vm_name, loc
      break if server.ready? 
      nretry -= 1
      sleep 5
    end
    rv = {}
    rv[:ip] = server.ipaddress    
    rv[:id] = server.vm_name
    rv
  end

  # @override... fricking ms
  def self.fetch_server id, loc
    s = get_auth loc
    server = s.servers.get(id, id)
  end


  def self.get_auth loc
    return @auth if @auth
    keys = get_keys loc
    management_cert = OpenSSL::PKCS12.new(Base64.decode64(keys[:apiKey]))
    f = Tempfile.new 'az'
    f.write management_cert.certificate.to_pem + management_cert.key.to_pem
    f.close
    @auth = Fog::Compute.new({:provider => 'Azure', :azure_sub_id => keys[:username], :azure_pem => f.path})
    @auth
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
    rv
  end

  def self._create_server name, scope, instance, loc, keyfile, image
    s = get_auth loc
    # XXX these firewall settings are for burstorm servers, think nothing of changing them...
    burfw = "2200:2200,80:80,443:443,12345:12345,12346:12346"
    server = s.servers.create(:vm_name => name, :image => image, :location => loc, :vm_size => instance, 
                              :private_key_file => keyfile, :vm_user => 'ubuntu', :tcp_endpoints => burfw)
    server
  end

  def self._delete_server id, loc
    begin
      server = self.fetch_server id, loc
      return if server.state != 'Running'
      if server
        server.destroy 
      end
    rescue Exception => e
      log "e=#{e.message}"
    end
  end

end


