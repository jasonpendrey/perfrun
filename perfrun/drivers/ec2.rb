require 'fog'

class Ec2Driver < Provider
  PROVIDER='Amazon/AWS'
  CHEF_PROVIDER='ec2'
  MAXJOBS = 2
  PROVIDER_ID = 67
  LOGIN_AS = 'ubuntu'
  DEFIMAGES = {'us-east-1' => 'ami-9a562df2', 'us-west-1' => 'ami-057f9d41', 'us-west-2' => 'ami-51526761',
    'eu-west-1' => 'ami-2396f654', 'eu-central-1' => 'ami-00dae61d', 'ap-southeast-1' => 'ami-76546924',
    'ap-southeast-2' => 'ami-cd611cf7', 'ap-northeast-1' => 'ami-c011d4c0', 'sa-east-1' => 'ami-75b23768' }

  @authlocs = {}

  def self.get_active location, all, &block
    s = get_auth location
    servers = s.servers.each do |server|
      if server.state == 'running' or all      
        yield server.id, server.tags['Name'], server.public_ip_address, server.state
      end
    end
  end	     

  def self.create_server name, scope, flavor, loc
    if flavor['keyname'].blank?
      puts "must specify keyname"
      return nil
    end
    image = flavor['imageid']
    image= DEFIMAGES[loc] if image.blank?
    server = self._create_server name, flavor['flavor'], loc, flavor['keyname'], image, false
    if server.nil?
      puts "can't create #{name}: #{server}"
      return nil
    end
    server.wait_for { 
      server.ready? 
    }
    rv = {}
    rv[:id] = server.id
    rv[:ip] = server.public_ip_address
    sleep 10
    rv
  end

  def self.get_auth loc
    return @authlocs[loc] if @authlocs[loc]
    keys = get_keys loc
    @authlocs[loc] = Fog::Compute.new(:provider => 'AWS', :aws_access_key_id => keys[:username], :aws_secret_access_key => keys[:apiKey], :region => loc)
  end

  # XXX there's probably a better way to read knife.rb...
  def self.get_keys loc
    ukey = "knife[:aws_access_key_id]"
    akey = "knife[:aws_secret_access_key]"
    rv = {}
    File.open(self.config loc).each do |line|
      # kill comments
      idx = line.index '#'
      unless idx.nil?
        line = line[0..idx-1]
      end
      if line.start_with? ukey
        l = line.split '='
        rv[:username] = l[1].strip[1..-2]
      end
      if line.start_with? akey
        l = line.split '='
        rv[:apiKey] = l[1].strip[1..-2]
      end
    end
    rv
  end

  def self._create_server name, instance, loc, keyname, image, createvol=false
    s = get_auth loc
    server = s.servers.create(:image_id => image, :flavor_id => instance, :key_name => keyname, :tags => {Name: name})
    server
  end

end
