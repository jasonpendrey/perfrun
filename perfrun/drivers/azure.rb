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

  @verbose = 0
  @keypath = "config"

  def self.get_active location, all, &block
    s = get_auth location
    s.servers.each do |server|
      if server.state == 'ready' or all      
        yield server.vm_name, server.vm_name, server.public_ip_address, server.deployment_status
      end
    end
  end	     

  def self.create_server name, scope, flavor, loc, provtags
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
    server = self._create_server name, scope, flavor['flavor'], loc, flavor['keyfile'], image
    if server.nil?
      puts "can't create #{name}: #{server}"
      return nil
    end
    server.wait_for { 
      server.ready? 
    }
    rv = {}
    rv[:ip] = server.ipaddress    
    rv[:id] = server.vm_name
    if flavor['provisioning'] == 'chef'
      sleep 1
      rv[:provisioning_out] = ChefDriver.bootstrap rv[:ip], name, provtags, flavor, loc, nil, config(loc) 
    end
    rv
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

end

# monkey patch... not working yet.

module Fog
  module Compute
    class Azure
      class Servers < Fog::Collection
#        model Fog::Compute::Azure::Server

        def get(identity, cloud_service_name=nil)
          cloud_service_name = identity unless cloud_service_name
          all.find { |f| f.name == identity && f.cloud_service_name == cloud_service_name }
        rescue Fog::Errors::NotFound
          nil
        end
      end
    end
  end
end



