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

  def self.config loc
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

  def self.gen_pass
    o = [('a'..'z'), ('A'..'Z'), ('0'..'9')].map { |i| i.to_a }.flatten
    string = (0...50).map { o[rand(o.length)] }.join
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

  def self.log msg
    begin
      File.write logfile, msg+"\n", mode: 'a'
    rescue
    end
  end

  def self.logfile
    "logs/#{self::CHEF_PROVIDER}.log"
  end


end
