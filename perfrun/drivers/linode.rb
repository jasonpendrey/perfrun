require 'fog'

class LinodeDriver < Provider

  PROVIDER='Linode'
  PROVIDER_ID = 90
  CHEF_PROVIDER='linode'
  MAXJOBS = 1
  LOGIN_AS = 'root'
  DEFIMAGE = '124'


  @verbose = 0
  @keypath = "config"

  def self.get_active location, all, &block
    s = get_auth location
    servers = s.servers.each do |server|
      if server.status == 1 or all      
        yield server.id, server.name, server.public_ip_address, server.status
      end
    end
  end	     


  def self.create_server name, scope, flavor, loc, provtags
    image = flavor['imageid']
    image = DEFIMAGE if image.blank?
    if flavor['flavor'].blank?
      puts "must specify flavor"
      return nil
    end
    if flavor['login_as'].blank?
      puts "must specify login_as"
      return nil
    end
    pass = gen_pass
    rv = {}
    server= self._create_server name, flavor['flavor'], loc, pass, image, false
    if server.nil?
      puts "can't create #{name}: #{server}"
      return nil
    end
    server.wait_for { 
      server.ready? 
    }
    rv[:pass] = pass
    rv[:id] = server.id
    rv[:ip] = server.public_ip_address
    if flavor['provisioning'] == 'chef'
      sleep 1
      rv [:provisioning_out] = ChefDriver.bootstrap rv[:ip], name, provtags, flavor, loc, pass, config(loc) 
    end
    rv
  end

  def self.get_auth loc
    return @auth if @auth
    keys = get_keys loc
    @auth = Fog::Compute.new(:provider => 'Linode', :linode_api_key => keys[:apiKey])
  end

  # XXX there's probably a better way to read knife.rb...
  def self.get_keys loc
    ukey = "knife[:linode_api_username]"
    akey = "knife[:linode_api_key]"
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

  def self._create_server name, instance, loc, pass, image=nil, createvol=false
    image = DEFIMAGE if image.nil?
    s = get_auth loc
    @flavors = s.flavors if @flavors.nil?
    @images = s.images if @images.nil?
    @data_centers = s.data_centers if @data_centers.nil?
    @kernels = s.kernels if @kernels.nil?

    flavor = @flavors.find { |f| f.id.to_s == instance.to_s }
    img = @images.find { |i|  i.id.to_s == image.to_s }
    kernel = @kernels.find { |k| k.name.start_with? "Latest 64 bit" }    
    dc = @data_centers.find { |dc| dc.id.to_s == loc.to_s }
    server = s.servers.create(:data_center => dc, :flavor => flavor, :name => name, :payment_terms => 0, 
                              :image => img, :kernel => kernel, :password => pass)
    server
  end
    
end
