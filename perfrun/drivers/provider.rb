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

  def self.gen_pass
    o = [('a'..'z'), ('A'..'Z'), ('0'..'9')].map { |i| i.to_a }.flatten
    string = (0...50).map { o[rand(o.length)] }.join
  end

  def self.fetch_server id, loc
    s = get_auth loc
    server = s.servers.get(id)
  end

  def self._delete_server id, loc
    begin
      server = self.fetch_server id, loc
      if server
        if server.respond_to? :destroy
          server.destroy 
        else
          server.delete
        end
      end
    rescue Exception => e
      puts "e=#{e.message}"
      puts e.backtrace.join "\n"
    end
  end

end
