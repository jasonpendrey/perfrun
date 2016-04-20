require "json"

class RackspaceDriver

  PROVIDER = 'Rackspace'
  PROVIDER_ID = 39
  CHEF_PROVIDER = 'rackspace'
  MAXJOBS = 1
  LOGIN_AS = 'root'
  IDENTURL = 'https://identity.api.rackspacecloud.com/v2.0/tokens'

  @auth = nil
  @location = 'DFW'
  @keypath = "config"

  def self.get_active location, all, &block  
    config = location.upcase == 'LON' ? ' -c .chef/knife.rsuk.rb ' : '';
    servers = `bundle exec knife #{CHEF_PROVIDER} server list --rackspace-region "#{location}" #{config}`
    srv = servers.split "\n"
    srv.shift
    srv.each do |s|
      line = s.split ' '
      id = line[0]
      name = line[1]
      flavor = line[4]
      ip = line[2]
      state = line.last
      if state == 'active' or all
        yield id, name, ip, state
      end
    end	     
  end

  def self.delete_server s, id, location, diskuuid=nil
    config = location.upcase == 'LON' ? ' -c .chef/knife.rsuk.rb ' : '';
    out = "yes|bundle exec knife #{CHEF_PROVIDER} server delete -N #{s}  #{id} --purge  --rackspace-region #{location} #{config}"
    if diskuuid
      out += "; ./perfrun --delete-rackspace-disk #{diskuuid}:#{location}"
    end
    out
  end

  def self.create_server name, flavor, location, provtags
    if location.upcase == "LON"
      config = ' -c .chef/knife.rsuk.rb '
    else
      config = ''
    end
    roles = []
    provtags.each do |tag|
      roles.push 'role['+tag+']'
    end
    roles = roles.join ','
    if flavor['flavor'].blank?
      puts "must specify flavor"
      return nil
    end
    if flavor['login_as'].blank?
      puts "must specify login_as"
      return nil
    end
    image = flavor['imageid']
    # 14.04 PVHVM
    image = '28153eac-1bae-4039-8d9f-f8b513241efe' if image.blank?
    rv = ''
    instance = flavor['flavor'].to_s
    if ! instance.start_with? "compute1-" and ! instance.start_with? "memory1-"
      image = "--image '#{image}'"
    else
      self.location = location
      uuid = create_volume name, image
      image = "-B '#{uuid}'"
      rv += uuid + "\n"
      rv += "DISKUUID: #{uuid}\n"
    end
    scriptln = "yes|bundle exec knife #{CHEF_PROVIDER} server create -r '#{roles}' --server-name '#{name}' -N '#{name}' #{image} --flavor '#{instance}' -V --ssh-user '#{flavor['login_as']}' --rackspace-region '#{location}' #{config} #{flavor['additional']} 2>&1"
    puts "#{scriptln}"
    IO.popen scriptln do |fd|
      fd.each do |line|
        puts line
        STDOUT.flush
        rv += line
      end
    end
    rv
  end

  def self.log msg
    File.write logfile, msg+"\n", mode: 'a'
  end

  def self.logfile
    "logs/#{CHEF_PROVIDER}.log"
  end


  def self.location= loc
    @location = loc
  end

  def self.keypath= path
    @keypath = path
  end

  # XXX there's probably a better way to read knife.rb...
  def self.get_keys
    if @location.upcase != 'LON'
      file = 'knife.rb'
    else
      file = 'knife.rsuk.rb'
    end
    ukey = "knife[:rackspace_api_username]"
    akey = "knife[:rackspace_api_key]"
    rv = {}
    file = "#{@keypath}/#{file}"
    File.open(file).each do |line|
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

  def self.curlauth method, endpoint=nil
    rv = "curl -X #{method} -H \"X-Auth-Token: #{@auth[:token]}\" -H \"Content-Type: application/json\" "
    rv += " #{@auth[endpoint]}" if endpoint
  end

  def self.get_auth
    location = @location.upcase
    return @auth if @auth and @authloc == location
    @authloc = location

    authjs = `curl -X 'POST' -s #{IDENTURL} -d '{"auth":{"RAX-KSKEY:apiKeyCredentials": #{get_keys.to_json}}}' -H "Content-Type: application/json"`
    # XXX
    auth = JSON.parse (authjs)
    @auth = { token: auth['access']['token']['id']}
    dnsendpoint = storageendpoint = serverendpoint = nil
    dnstenant = storetenant = servertenant = nil
    auth['access']['serviceCatalog'].each do |service|
      if service['name'] == 'cloudBlockStorage'
        service['endpoints'].each do |ep|
          next if ep['region'] != location
          @auth[:storagetenant] = ep['tenantId']
          @auth[:storageendpoint] = ep['publicURL']
          break
        end
      elsif service['name'] == 'cloudServers'
        service['endpoints'].each do |ep|
          @auth[:servertenant] = ep['tenantId']
          @auth[:serverendpoint] = ep['publicURL']
          break
        end
      elsif service['name'] == 'cloudDNS'
        service['endpoints'].each do |ep|
          @auth[:dnstenant] = ep['tenantId']
          @auth[:dnsendpoint] = ep['publicURL']
          break
        end
      end
    end
    @auth
  end

  def self.list_domains
    self.get_auth
    cmd = "#{curlauth('GET', :dnsendpoint)}/domains/ 2>/dev/null"
    cvol = `#{cmd}`
    JSON.parse (cvol)
  end

  def self.domainid domain
    self.get_auth
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
    }.to_json
    cmd = "#{curlauth('POST', :dnsendpoint)}/domains/#{id}/records -d '#{req}'  2>/dev/null"
    rv = `#{cmd}`    
    JSON.parse (rv)
  end

  def self.fetch_dns domain, label
    id = domainid domain
    cmd = "#{curlauth('GET', :dnsendpoint)}/domains/#{id}/records 2>/dev/null"
    rv = `#{cmd}`
    rv = JSON.parse (rv)    
    return nil if rv.nil?
    rv['records'].each do |r|
      return r if r['name'] == "#{label}.#{domain}"
    end
    nil
  end

  def self.del_dns domain, label
    r = fetch_dns domain, label
    return nil if r.nil?
    cmd = "#{curlauth('DELETE', :dnsendpoint)}/domains/#{@curdomain['id']}/records/#{r['id']}\" 2>/dev/null"
    rv = `#{cmd}`
    JSON.parse (rv)
  end

  def self.list_volumes
    self.get_auth
    cmd = "#{curlauth('GET', :storageendpoint)}/volumes 2>/dev/null"
    cvol = `#{cmd}`
    JSON.parse (cvol)
  end

  def self.list_volume uuid
    self.get_auth
    cmd = "#{curlauth('GET', :storageendpoint)}/volumes/#{uuid} 2>/dev/null"
    cvol = `#{cmd}`
    JSON.parse (cvol)
  end

  def self.create_volume name, image
    self.get_auth
    req = "{
        \"volume\": {
           \"display_name\": \"perf-#{name}\",
           \"imageRef\": \"#{image}\", 
           \"availability_zone\": null, 
           \"volume_type\": \"SSD\", 
           \"display_description\": null, 
           \"snapshot_id\": null, 
           \"size\": 50
        }
      }"
    cmd = "#{curlauth('POST', :storageendpoint)}/volumes -d '#{req}'  2>/dev/null"
    cvol = `#{cmd}`
    rv = JSON.parse (cvol)
    uuid="#{rv['volume']['id']}"
    while true
      cvol = `#{curlauth('GET', :storageendpoint)}/volumes/#{uuid} 2>/dev/null`
      begin 
        rv = JSON.parse (cvol)  
        if rv['volume'].nil?
          puts "ignoring volume create message: cvol=#{cvol}" unless rv['itemNotFound']
        elsif rv['volume']['status'] != 'creating'
          break 
        end
      rescue Exception => e
        puts "error parsing volume create status: cvol=#{cvol}"
      end
      sleep 10
    end
    return uuid
  end

  def self.delete_volume vol
    self.get_auth
    name = vol['display_name'] || vol['id']
    cmd = "#{curlauth('DELETE', :storageendpoint)}/volumes/#{vol['id']} 2>/dev/null"
    retrycnt = 20
    while retrycnt > 0
      rv = `#{cmd}`    
      break if ! rv.start_with? '{"badRequest": {"message": "Invalid volume: Volume status must be available or error, but current status is: in-use", "code": 400}'
      sleep 10
      retrycnt -= 1
    end
    if retrycnt == 0
      return nil
    end
    rv
  end

  def self.create_server instance, uuid
    self.get_auth
    req = {
      server: {
        name: name, 
        imageRef: "", 
        block_device_mapping: [{
                                 volume_id: uuid, 
                                 delete_on_termination: '1', 
                                 device_name: 'vda'
                               }], 
        flavorRef: instance, 
        max_count: 1, 
        min_count: 1, 
        networks: [
            { uuid: "00000000-0000-0000-0000-000000000000" }, 
            { uuid: "11111111-1111-1111-1111-111111111111" }
        ]
      }
    }
    cmd = "#{curlauth('POST', :serverendpoint)}/servers -d '#{req.to_json} 2>/dev/null"
    cvol = `#{cmd}`
    rv = JSON.parse (cvol)
  end

  def self.log msg
    File.write logfile, msg+"\n", mode: 'a'
  end

  def self.logfile
    "logs/rackspace.log"
  end

end
