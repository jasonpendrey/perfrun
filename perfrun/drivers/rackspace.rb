require "json"

class RackspaceDriver < Provider

  PROVIDER = 'Rackspace'
  PROVIDER_ID = 39
  LOG_PROVIDER = 'rackspace'
  MAXJOBS = 1
  LOGIN_AS = 'root'
  IDENTURL = 'https://identity.api.rackspacecloud.com/v2.0/tokens'
  DEFIMAGE = '28153eac-1bae-4039-8d9f-f8b513241efe'   # Unbuntu 14.04 PVHVM

  @authlocs = {}

  def self.get_active loc, all, &block      
    srvs = list_servers loc
    srvs['servers'].each do |server|
      state = server['status']
      id = server['id']
      ip = server['accessIPv4']
      name = server['name']
      if state == 'ACTIVE' or all
        yield id, name, ip, state
      end      
    end
  end

  def self.delete_server name, id, loc, flavor
    self._delete_server id, loc
    nil
  end

  def self.create_server name, scope, flavor, loc
    loc = loc.upcase
    keyname = flavor['keyname']
    image = flavor['imageid']
    image = DEFIMAGE if image.blank?
    instance = flavor['flavor'].to_s
    createvol = false
    if instance.start_with? "compute1-" or instance.start_with? "memory1-"
      createvol = true
    end
    server = self._create_server name, scope, instance, loc, keyname, image, createvol
    if server.nil? or ! server['server']
      log "can't create #{name}: #{server}"
      return nil
    end   
    rv = {}
    rv[:id] = server['server']['id']
    if keyname.blank?
      rv[:pass] = server['server']['adminPass']      
    end
    nretry = 30
    while nretry > 0 do
      sleep 10
      s = self.fetch_server rv[:id], loc
      if s.nil? or ! s['server']
        log "bad fetch_server: #{s}"
        return nil
      end
      log "#{name} status: #{s['server']['status']}" if @verbose > 0
      begin
      if s['server']['status'] == 'ACTIVE'
        rv[:ip] = s['server']['accessIPv4']
        break
      end
      rescue Exception => e
        log "server=#{s}"
      end
      nretry -= 1
    end
    if nretry <= 0
      log "ERROR: timed out creating #{name}"
      return nil
    end
    sleep 10
    rv
  end

  def self.get_keys loc
    if loc.upcase != 'LON'
      rv = super({:rackspace_api_username => nil, :rackspace_api_key => nil}, loc)
      rv[:username] = rv[:rackspace_api_username]
      rv.delete :rackspace_api_username
      rv[:apiKey] = rv[:rackspace_api_key]
      rv.delete :rackspace_api_key
    else
      rv = super({:rackspace_lon_api_username => nil, :rackspace_lon_api_key => nil}, loc)
      rv[:username] = rv[:rackspace_lon_api_username]
      rv.delete :rackspace_lon_api_username
      rv[:apiKey] = rv[:rackspace_lon_api_key]
      rv.delete :rackspace_lon_api_key
    end
    rv

  end

  def self.curlauth method, loc, endpoint=nil
    auth = self.get_auth loc
    rv = "curl -X #{method} -H \"X-Auth-Token: #{auth[:token]}\" -H \"Content-Type: application/json\" "
    rv += " #{auth[endpoint]}" if endpoint
  end

  def self.get_auth loc
    if @authlocs[loc]
      return @authlocs[loc]
    end
    cmd = "curl -X 'POST' -s #{IDENTURL} -d '{\"auth\":{\"RAX-KSKEY:apiKeyCredentials\": #{JSON.generate(get_keys(loc))}}}' -H \"Content-Type: application/json\""
    authjs = `#{cmd}`
    # XXX
    begin
      auth = JSON.parse (authjs)
    rescue Exception => e
      log "can't get rs auth: #{cmd}"
      log "rv: #{authjs}"
      raise e
    end
    if auth['access'].nil?      
      log "can't get rs auth: #{cmd}"
      log "rv: #{authjs}"
      raise e
    end
    rv = { token: auth['access']['token']['id']}
    dnsendpoint = storageendpoint = serverendpoint = nil
    dnstenant = storetenant = servertenant = nil
    auth['access']['serviceCatalog'].each do |service|
      if service['name'] == 'cloudBlockStorage'
        service['endpoints'].each do |ep|
          next if ep['region'] != loc
          rv[:storagetenant] = ep['tenantId']
          rv[:storageendpoint] = ep['publicURL']
          break
        end
      elsif service['name'] == 'cloudServersOpenStack'
        service['endpoints'].each do |ep|          
          next if ep['region'] != loc
          rv[:servertenant] = ep['tenantId']
          rv[:serverendpoint] = ep['publicURL']
          break
        end
      elsif service['name'] == 'cloudDNS'
        service['endpoints'].each do |ep|
          rv[:dnstenant] = ep['tenantId']
          rv[:dnsendpoint] = ep['publicURL']
          break
        end
      end
    end
    @authlocs[loc] = rv
  end

  def self.execcmd cmd
    begin
      out = `#{cmd}`
      if out.blank?
        log "empty output for: #{cmd}"
        return nil 
      end
      rv = JSON.parse(out)
    rescue Exception => e
      log "error: #{e.message}"
      log "cmd= #{cmd}"
      nil
    end
    rv
  end

  def self.list_domains
    cmd = "#{curlauth('GET', "DFW", :dnsendpoint)}/domains/ 2>/dev/null"
    execcmd cmd
  end

  def self.domainid domain
    domains = list_domains
    return nil if domains.nil?
    domains['domains'].each do |d|
      if d['name'] == domain
        @curdomain = d
        return d['id']
      end
    end
    nil
  end

  def self.add_dns domain, label, ip, ttl=300
    id = domainid domain
    req = { records: [{
                        name: "#{label}.#{domain}",
                        type: "A",
                        data: ip,
                        ttl: ttl
                      }]
    }
    cmd = "#{curlauth('POST', "DFW", :dnsendpoint)}/domains/#{id}/records -d '#{JSON.generate(req)}'  2>/dev/null"
    execcmd cmd
  end

  def self.fetch_dns domain, label
    id = domainid domain
    cmd = "#{curlauth('GET', "DFW", :dnsendpoint)}/domains/#{id}/records 2>/dev/null"
    rv = execcmd cmd
    return nil if rv.nil?
    rv['records'].each do |r|
      return r if r['name'] == "#{label}.#{domain}"
    end
    nil
  end

  def self.del_dns domain, label
    r = fetch_dns domain, label
    return nil if r.nil?
    cmd = "#{curlauth('DELETE', "DFW", :dnsendpoint)}/domains/#{@curdomain['id']}/records/#{r['id']} 2>/dev/null"
    execcmd cmd
  end

  def self.list_volumes loc
    cmd = "#{curlauth('GET', loc, :storageendpoint)}/volumes 2>/dev/null"
    execcmd cmd
  end

  def self.list_volume uuid, loc
    cmd = "#{curlauth('GET', loc, :storageendpoint)}/volumes/#{uuid} 2>/dev/null"
    execcmd cmd
  end

  def self.fetch_volume id, loc
    cmd = "#{curlauth('GET', loc, :storageendpoint)}/volumes/#{id} 2>/dev/null"
    execcmd cmd
  end

  def self.create_volume name, image, loc
    req = {
      volume: {
        display_name: "perf-#{name}",
        imageRef: image, 
        availability_zone: nil, 
        volume_type: "SSD", 
        display_description: nil, 
        snapshot_id: nil, 
        size: 50
      }
    }
    cmd = "#{curlauth('POST', loc, :storageendpoint)}/volumes -d '#{JSON.generate(req)}'  2>/dev/null"
    rv = execcmd cmd
    uuid = rv['volume']['id']
    log "uuid of new volume: #{uuid}"
    nretry = 30
    while nretry > 0
      sleep 10
      r = fetch_volume uuid
      if r['volume'].nil?
        log "ignoring volume create message: vol=#{r}" unless r['itemNotFound']
      elsif r['volume']['status'] == 'available'
        break 
      else
        log "#{uuid}: #{r['volume']['status']}" if @verbose > 0
      end
      nretry -= 1
    end
    return rv
  end

  def self.delete_volume vol, loc
    name = vol['display_name'] || vol['id']
    cmd = "#{curlauth('DELETE', loc, :storageendpoint)}/volumes/#{vol['id']} 2>/dev/null"
    retrycnt = 20
    while retrycnt > 0
      rv = execcmd cmd
      if rv['badRequest']
        if rv['badRequest']['message'] == "Invalid volume: Volume status must be available or error, but current status is: in-use"
          sleep 10
          retrycnt -= 1
        else
          return nil
        end
      else
        break
      end
    end
    if retrycnt == 0
      return nil
    end
    rv
  end

  def self.list_servers loc
    cmd = "#{curlauth('GET', loc, :serverendpoint)}/servers/detail 2>/dev/null"
    execcmd cmd
  end


  def self._create_server name, scope, instance, loc, keyname=nil, image=nil, createvol=false
    image = DEFIMAGE if image.nil?
    req = {
      server: {
        name: name, 
        imageRef: image, 
        flavorRef: instance, 
        max_count: 1,     # xxx don't know what these do, and rs dox suck
        min_count: 1,     # xxx
      }
    }
    if createvol
      req[:server][:imageRef] = nil
      storage = scope['storage'] || 20
      storage = 20 if storage < 20
      req[:server][:block_device_mapping_v2] = [{ delete_on_termination: true,
                                                  boot_index: '0',
                                                  destination_type: 'volume',
                                                  uuid: image,
                                                  source_type: 'image',
                                                  volume_size: storage,
                                                }]
    end
    req[:server][:key_name] = keyname unless keyname.blank?
    networks = [
                { uuid: "00000000-0000-0000-0000-000000000000" }, 
                { uuid: "11111111-1111-1111-1111-111111111111" }
               ]
    req[:server][:networks] = networks
    cmd = "#{curlauth('POST', loc, :serverendpoint)}/servers -d '#{JSON.generate(req)}' 2>/dev/null"
    execcmd cmd
  end

  def self.fetch_server id, loc
    cmd = "#{curlauth('GET', loc, :serverendpoint)}/servers/#{id} 2>/dev/null"
    execcmd cmd
  end


  def self._delete_server id, loc
    cmd = "#{curlauth('DELETE', loc, :serverendpoint)}/servers/#{id} 2>/dev/null"
    rv = `#{cmd}`
  end

end
