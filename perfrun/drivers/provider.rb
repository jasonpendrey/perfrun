# base class for cloud provider drivers

class Provider
  @verbose = 0

  class << self; attr_accessor :keypath end
  @keypath = "config"

  def self.verbose= n
    @verbose = n
    ChefDriver.verbose = n
  end

  def self.delete_server name, id, loc, flavor
    self._delete_server id, loc
    nil
  end

  def self.config
    path = self.keypath || 'config'
    path + '/knife.rb'
  end

  def self.flavordefaults scope, nullflavorok=false
    flavor = scope['flavor']
    return nil if flavor.nil?
    if flavor['flavor'].blank? and ! nullflavorok
      raise "must specify flavor for #{scope['id']}"
    end
    flavor['login_as'] = self::LOGIN_AS #if flavor['login_as'].blank?
    flavor['sshport'] = '22' if flavor['sshport'].blank?
    unless flavor['keyfile'].blank?
      if ! flavor['keyfile'].include?('/') and ! flavor['keyfile'].include?('..')
        flavor['keyfile'] = "#{Dir.pwd}/config/#{flavor['keyfile']}"
      end
    else
      flavor['keyfile'] = "#{Dir.pwd}/config/servers.pem"
    end
    flavor
  end

  def self.gen_pass n=50
    o = [('a'..'z'), ('A'..'Z'), ('0'..'9')].map { |i| i.to_a }.flatten
    string = (0...n).map { o[rand(o.length)] }.join
  end

  def self.fetch_server id, loc
    begin
      s = get_auth loc
      server = s.servers.get(id)
    rescue
      nil
    end
  end

  def self._delete_server id, loc
    server = nil
    begin
      server = self.fetch_server id, loc
      unless server.nil?
        if server.respond_to? :destroy
          server.destroy 
        else
          server.delete
        end
      end
    rescue Exception => e
      log "delete error: e=#{e.message} from: #{server.inspect}"
    end
  end

  def self.get_keys keys, loc
    rv = load_knife keys, loc
    return rv unless rv.nil?
    # old knife parsing... 
    if File.exist? self.config
      File.open(self.config).each do |line|
        # kill comments
        idx = line.index '#'
        unless idx.nil?
          line = line[0..idx-1]
        end
        keys.each_pair do |key, val|
          if line.start_with? "knife[:#{key}]"
            l = line.split '='
            keys[key] = l[1].strip[1..-2]
          end
        end
      end
    end
    keys
  end

  def self.load_knife keys, loc
    def self.log_level p
    end
    def self.log_location p
    end
    def self.node_name p
    end
    def self.client_key p
    end
    def self.chef_server_url p
    end
    def self.cache_type p
    end
    def self.cache_options p
    end
    def self.cookbook_path p
    end

    knife = {}
    cfg = File.read self.config
    begin
      eval cfg
    rescue Exception => e
      puts "knife parse error: #{e.message}"
      return nil
    end
    keys.each_pair do |k,v| 
      keys[k] = knife[k]
    end
    keys
  end
  
  def self.log msg
    begin
      File.write logfile, msg+"\n", mode: 'a'
    rescue
    end
  end

  def self.logfile
    "logs/#{self::LOG_PROVIDER}.log"
  end
end

