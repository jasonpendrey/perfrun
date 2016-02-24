require "json"

class RackspaceDriver

  PROVIDER = 'Rackspace'
  PROVIDER_ID = 39
  CHEF_PROVIDER = 'rackspace'
  MAXJOBS = 1
  LOGIN_AS='root'
  @locations_visited = []

  # @override
  def self.fullinstname instname, instloc
    instname+'-'+instloc.gsub(' ', '-')
  end

  def self.get_active location, all, &block  
    config = location.upcase == 'LON' ? ' -c .chef/knife.rsuk.rb ' : '';
    servers = `bundle exec knife rackspace server list --rackspace-region "#{location}" #{config}`
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

  def self.create_server name, instance, location, login_as, ident
    roles = ""
    @locations_visited.push location
    if location.upcase == "LON"
      config = ' -c .chef/knife.rsuk.rb '
    else
      config = ''
    end
    # 14.04 PVHVM
    image = '28153eac-1bae-4039-8d9f-f8b513241efe'
    out = ''
    instance = instance.to_s
    if ! instance.start_with? "compute1-" and ! instance.start_with? "memory1-"
      out += `yes|bundle exec knife rackspace server create -r "#{roles}" --server-name #{name} -N #{name} --image #{image} --flavor #{instance} -V --rackspace-region "#{location}" #{config}  2>&1`
    else
      uuid = RackspaceVolumes.create_volume name, image, location
      out += uuid + "\n"
      out += "DISKUUID: #{uuid}\n"
      out += `yes|bundle exec knife rackspace server create -r "#{roles}" --server-name #{name} -N #{name} -B "#{uuid}" --flavor #{instance} -V --rackspace-region "#{location}" #{config} 2>&1`
    end
    out
  end

  def cleanup
    # XXX wrong now
    opts = @opts.clone
    opts[:mode] = :delete
    r = self.class.new
    r.run opts
    # XXX
    system "reset -I 2>/dev/null"
    @locations_visited.uniq!
    @locations_visited.each do |location|
      RackspaceVolumes.list_volumes(location)['volumes'].each do |vol|
        if vol['display_name'].start_with? 'perf-'
          rv = RackspaceVolumes.delete_volume vol, location
          log "deleted vol=#{vol['display_name']} uuid=#{vol['id']}"
        end
      end
    end
  end

  def self.log msg
    File.write logfile, msg+"\n", mode: 'a'
  end

  def self.logfile
    "logs/#{CHEF_PROVIDER}.log"
  end

end

class RackspaceVolumes
  @auth = nil

  def self.get_auth location    
    location = location.upcase
    return @auth if @auth and @authloc == location
    @authloc = location
    if location != 'LON'
      authjs = `curl -s https://identity.api.rackspacecloud.com/v2.0/tokens -X 'POST' \
	-d '{"auth":{"RAX-KSKEY:apiKeyCredentials":{"username":"burstormadmin", "apiKey":"89c0c9f870eee080433266b2eebf52c7"}}}' \
	-H "Content-Type: application/json"`
    else
      authjs = `curl -s https://identity.api.rackspacecloud.com/v2.0/tokens -X 'POST' \
	-d '{"auth":{"RAX-KSKEY:apiKeyCredentials":{"username":"burstormadminuk", "apiKey":"0a31af55ac314e42a7d48b42fd7ea998"}}}' \
	-H "Content-Type: application/json"`
    end
    auth = JSON.parse (authjs)
    authtoken = auth['access']['token']['id']
    storageendpoint = serverendpoint = nil
    tenant = nil
    auth['access']['serviceCatalog'].each do |service|
      if service['name'] == 'cloudBlockStorage'
        service['endpoints'].each do |ep|
          tenant = ep['tenantId'] if ! tenant
          next if ep['region'] != location
          storageendpoint = ep['publicURL']
          break
        end
      elsif service['name'] == 'cloudServers'
        service['endpoints'].each do |ep|
          serverendpoint = ep['publicURL']
          break
        end
      end
    end
    @auth = { token: authtoken, tenant: tenant, serverendpoint: serverendpoint, storageendpoint: storageendpoint}
  end

  def self.list_volumes location
    self.get_auth location
    cmd = "curl -X GET  -H \"X-Auth-Token: #{@auth[:token]}\" -H \"Content-Type: application/json\" \"#{@auth[:storageendpoint]}/volumes\" 2>/dev/null"
    cvol = `#{cmd}`
    rv = JSON.parse (cvol)
  end

  def self.create_volume name, image, location
    self.get_auth location
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
    cmd = "curl -X POST -d '#{req}' -H \"X-Auth-Token: #{@auth[:token]}\" -H \"Content-Type: application/json\" #{@auth[:storageendpoint]}/volumes 2>/dev/null"
    cvol = `#{cmd}`
    rv = JSON.parse (cvol)
    uuid="#{rv['volume']['id']}"
    log "creating volume #{name}"
    while true
      cvol = `curl -X GET -H \"X-Auth-Token: #{@auth[:token]}\" -H \"Content-Type: application/json\" #{@auth[:storageendpoint]}/volumes/#{uuid} 2>/dev/null`
      begin 
        rv = JSON.parse (cvol)  
        if rv['volume'].nil?
          log "ignoring volume create message: cvol=#{cvol}" unless rv['itemNotFound']
        elsif rv['volume']['status'] != 'creating'
          break 
        end
      rescue Exception => e
        log "error parsing volume create status: cvol=#{cvol}"
      end
      sleep 10
    end
    return uuid
  end

  def self.delete_volume vol, location
    self.get_auth location
    name = vol['display_name'] || vol['id']
    cmd = "curl -X DELETE  -H \"X-Auth-Token: #{@auth[:token]}\" -H \"Content-Type: application/json\" \"#{@auth[:storageendpoint]}/volumes/#{vol['id']}\" 2>/dev/null"
    retrycnt = 20
    while retrycnt > 0
      rv = `#{cmd}`    
      break if ! rv.start_with? '{"badRequest": {"message": "Invalid volume: Volume status must be available or error, but current status is: in-use", "code": 400}'
#      log "retrying: #{name}/#{location}/#{vol['id']} #{rv}"
      sleep 10
      retrycnt -= 1
    end
    if retrycnt == 0
      log "Can't delete volume #{vol['id']} at #{location}" 
      return nil
    end
    log "rackspace disk delete #{vol}/#{location}: #{rv}"
    rv
  end

  def self.create_server location, instance, uuid
    self.get_auth location
    req = "{
    \"server\": {
        \"name\": \"#{name}\", 
        \"imageRef\": \"\", 
        \"block_device_mapping\": [
            {
                \"volume_id\": \"#{uuid}\", 
                \"delete_on_termination\": \"1\", 
                \"device_name\": \"vda\"
            }
        ], 
        \"flavorRef\": \"#{instance}\", 
        \"max_count\": 1, 
        \"min_count\": 1, 
        \"networks\": [
            {
                \"uuid\": \"00000000-0000-0000-0000-000000000000\"
            }, 
            {
                \"uuid\": \"11111111-1111-1111-1111-111111111111\"
            }
        ]
      }
    }"

    cmd = "curl -X POST -d '#{req}' -H \"X-Auth-Token: #{@auth[:token]}\" -H \"Content-Type: application/json\" https://#{location.downcase}.servers.api.rackspacecloud.com/v2/#{@auth[:tenant]}/servers 2>/dev/null"
    cvol = `#{cmd}`
    rv = JSON.parse (cvol)
    log "rv=#{rv.inspect}"
  end

  def self.log msg
    File.write logfile, msg+"\n", mode: 'a'
  end

  def self.logfile
    "logs/rackspace.log"
  end

end
