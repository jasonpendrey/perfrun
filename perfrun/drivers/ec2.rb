require 'fog'

class Ec2Driver < Provider
  PROVIDER='Amazon/AWS'
  CHEF_PROVIDER='ec2'
  MAXJOBS = 1
  PROVIDER_ID = 67
  LOGIN_AS = 'ubuntu'

  @verbose = 0
  @keypath = "config"

  def self.get_active location, all, &block
    s = get_auth location
    servers = s.servers.each do |server|
      if server.state == 'running' or all      
        yield server.id, server.tags['Name'], server.public_ip_address, server.state
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
    if image.blank?
      case loc
      when 'us-east-1'
        image = 'ami-9a562df2'
      when 'us-west-1'
        image = 'ami-057f9d41'
      when 'us-west-2'
        image = 'ami-51526761'
      when 'eu-west-1'
        image = 'ami-2396f654'
      when 'eu-central-1'
        image = 'ami-00dae61d'
      when 'ap-southeast-1'
        image = 'ami-76546924'
      when 'ap-southeast-2'
        image = 'ami-cd611cf7'
      when 'ap-northeast-1'
        image = 'ami-c011d4c0'
      when 'sa-east-1'
        image = 'ami-75b23768'
      end
    end
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

  def self.get_auth loc
    return @auth if @auth
    keys = get_keys loc
    @auth = Fog::Compute.new(:provider => 'AWS', :aws_access_key_id => keys[:username], :aws_secret_access_key => keys[:apiKey], :region => loc)
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
