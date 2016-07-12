class CenturylinkDriver < Provider
  PROVIDER='CenturyLink'
  LOG_PROVIDER='centurylink'
  MAXJOBS = 1
  PROVIDER_ID = 931
  LOGIN_AS = 'root'
  DEFIMAGE='Ubuntu-14-64-TEMPLATE'

  def self.get_active location, all, &block
    get_auth location
    rv = get_group @keys[:centurylink_groupid]
    rv['links'].each do |link|
      next if link['rel'] != 'server'
      server = fetch_server link['id']
      next if server.nil? or server['locationId'] != location
      if server['status'] == 'active' or all      
        ip = nil
        if server['details'] and server['details']['ipAddresses']
          server['details']['ipAddresses'].each do |ipline|
            next if ipline['public'].nil?
            ip = ipline['public']
          end
        end
        yield server['id'], server['description'], ip, server['status']
      end
    end
  end	     

  def self.vmname name
    name[0..6]
  end

  def self.create_server name, scope, flavor, loc
    get_auth loc
    image = flavor['imageid']
    image = DEFIMAGE if image.blank?
    server = self._create_server name, scope, loc, image
    if server.nil?
      log "can't create #{name}: #{server}"
      return nil
    end
    pass = server['password']
    stslink = nil
    idlink = nil
    server['links'].each do |link|
      if link['rel'] == 'status'
        stslink = link
      end
      if link['rel'] == 'self'
        idlink = link
      end
    end
    if stslink.nil?
      log "can't get create status for #{name}: #{server.inspect}"
      return nil
    end
    if idlink.nil?
      log "can't get id for #{name}: #{server.inspect}"
      return nil
    end
    return nil unless wait_for "#{curlauth 'GET', 'operations'}/status/#{stslink['id']}"    
    server = fetch_server idlink['id'], true
    server = add_ip server
    return nil if server.nil?
    server[:name] = server['description']
    server[:pass] = pass
    server[:ip] = server['public_ip']
    server[:id] = server['name']
    server
  end

  def self.fetch_server name, isuuid=false
    if isuuid
      return execcmd "#{curlauth 'GET', 'servers'}/#{name}?uuid=true"    
    else
      return execcmd "#{curlauth 'GET', 'servers'}/#{name}"    
    end
  end

  def self.add_ip server
    fw = { "ports":[{"protocol":"TCP", "port":22}, {"protocol":"ICMP", "port":0}]}
    stslink = execcmd "#{curlauth 'POST', 'servers'}/#{server['name']}/publicIPAddresses -d '#{fw.to_json}'" 
    return nil if ! stslink
    return nil unless wait_for "#{curlauth 'GET', 'operations'}/status/#{stslink['id']}"
    server = fetch_server server['name']
    ip = nil
    if server['details'] and server['details']['ipAddresses']
      server['details']['ipAddresses'].each do |ipline|
        next if ipline['public'].nil?
        ip = ipline['public']
      end
    end
    server['public_ip'] = ip
    server
  end
  
  def self.delete_server name, id, loc, flavor
    get_auth loc
    execcmd "#{curlauth 'DELETE', 'servers'}/#{id}"
    nil
  end

  def self.curlauth method, cmd
    auth = self.get_auth
    rv = "curl -s -X #{method} -H \"Authorization: Bearer #{auth['bearerToken']}\" -H \"Content-Type: application/json\" "
    rv += "https://api.ctl.io/v2/#{cmd}/#{auth['accountAlias']}"
  end

  def self.execcmd cmd
    begin
      out = `#{cmd}`
      if out.blank?
        log "empty output for: #{cmd}"
        return nil 
      end
      rv = JSON.parse(out)
      if rv['message']
        log "curl returned error: #{rv['message']}"
        log " cmd=#{cmd}"
        return nil
      end
    rescue Exception => e
      log "error: #{e.message}"
      log "cmd= #{cmd}"
      nil
    end
    rv
  end

  def self.wait_for cmd
    tmo = 0
    sleeptime = 5
    while true do
      sts = execcmd cmd
      if sts
        break if sts['status'] == 'succeeded'
        if sts['status'] == 'failed' or sts['message']
          log "cmd failed: sts=#{sts['status']} msg=#{sts['message']}"
          return nil
        end
      end
      sleep sleeptime
      tmo += sleeptime
      if tmo > 600
        log "#{cmd}: timed out"
        return nil
      end
    end
    true
  end

  def self.get_auth loc=nil
    @location = loc if loc
    return @auth if @auth and @auth[:location] == @location
    get_keys @location
    url = 'https://api.ctl.io/v2/authentication/login'
    jkeys = {
      "username": @keys[:centurylink_username],
      "password": @keys[:centurylink_password]
    }
    cmd = "curl -s -X POST -H \"Content-Type: application/json\" -d '#{jkeys.to_json}' #{url}"
    rv = `#{cmd}`
    begin
      @auth = JSON.parse rv      
    rescue
    end
    @auth[:location] = @location
    @auth
  end

  def self.get_keys loc
    @keys = super({:centurylink_username =>nil, :centurylink_password =>nil, :centurylink_locations=>nil}, loc)
    @keys[:centurylink_groupid] = @keys[:centurylink_locations][loc.upcase]
  end

  def self._create_server name, scope, loc, image
    get_auth loc
    cpu = scope['cores'] || 1
    ram = scope['ram'] || 2
    storage = scope['storage'] || 20
    storage = 20 if storage < 20
    if (! scope['is_virtualized'] and ! scope['is_shared'])
      vtype = 'bareMetal'
    elsif scope['seek_tech'] == 1
      vtype = 'hyperscale'
    else
      vtype = 'standard'
    end
    pass = gen_pass(20)+'aA1$'
    opts = {:name => vmname(name), :description => name, :groupId => @keys[:centurylink_groupid], :sourceServerId => image,
      :cpu => cpu, :memoryGB => ram,
      :type => vtype,
      :password => pass,
    }      
    server = execcmd( cmd = "#{curlauth 'POST', 'servers'} -d '#{opts.to_json}'")
    if server
      server['password'] = pass
    end
    server
  end

  def self.get_dcs
    execcmd "#{curlauth 'GET', 'datacenters'}"
  end
  def self.get_dc dc
    execcmd "#{curlauth 'GET', 'datacenters'}/#{dc}"
  end

  def self.get_group g
    rv = execcmd "#{curlauth 'GET', 'groups'}/#{g}"
    rv
  end

  # @override
  def self.flavordefaults scope
    super scope, true
  end

end
