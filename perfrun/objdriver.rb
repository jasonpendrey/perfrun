require 'active_support/all'  # for camelize
require_relative 'drivers/provider'
require_relative 'drivers/provisioning'
require_relative 'drivers/chef'


class ObjDriver
  WATCHDOGTMO = 30*60       # for running
  SSHOPTS = "-o LogLevel=quiet -oStrictHostKeyChecking=no"
  CONNECTRETRY = 10
  CONNECTRETRYTMO = 10
  
  attr_accessor :maxjobs

  def initialize
    @threads = []
    @verbose = 0
  end

  def run opts, &block
    @app_host = $apphost || APP_HOST
    @opts = opts
    @aborted = false
    object = opts[:object]
    @tags = opts[:tags]
    @mode = opts[:mode]    
    if opts[:scopes]
      @targscopes = []
      opts[:scopes].each do |s|
        @targscopes.push scopename(s)
      end
    end
    @verbose = opts[:verbose] || 0
    @autodelete = opts[:autodelete]    
    @testconnection = opts[:test_connection]
    @curprovider = object['provider']['name']
    @curlocation = object['provider']['location_flavor'] || object['provider']['address']
    @started_at = Time.now if @mode == 'run'
    @app_host = opts[:app_host] if opts[:app_host]
    @errorinsts = [] if @mode == 'run'
    @threads = []
    @mutex = Mutex.new
    watchdog
    log "Running #{object['name']}@#{@curprovider}/#{@curlocation} to #{@app_host}" if @mode == 'run'
    @actives = {}
    begin
      object['compute_scopes'].each do |scope|
        break if @aborted
        next if @targscopes and ! @targscopes.include? scopename(scope)
        set_driver object, scope
        flavor = flavordefaults scope
        next if flavor.nil?
        @maxjobs = opts[:maxjobs] || maxjobs
        provloc = @curprovider+@curlocation
        if @actives[provloc].nil?          
          active = {}
          alines = []
          get_active @curlocation, @mode != 'run' do |id, name, ip, state|
            active[name] = name
            alines.push({id:id, name:name, ip:ip, state: state})
          end
          active = active.values
          @actives[provloc] = {active: active, alines: alines}
        else
          alines = @actives[provloc][:alines]
          active = @actives[provloc][:active]
        end
        fullname = fullinstname scope
        log "Running #{fullname}..." if @mode == 'run'
        aline = nil
        alines.each do |a|
          next if a[:name] != fullname
          aline = a
          break
        end
        if @mode == 'run'
          @pubkey = `ssh-keygen -y -f #{File.expand_path flavor['keyfile']}`
          raise "can't access #{flavor['keyfile']}" if @pubkey.nil? or @pubkey.empty?
          curthread = {started_at:Time.now, fullname: fullname, inst: scopename(scope), loc: @curlocation, state: 'starting'}
          curthread[:thread] = Thread.new {
            curthread[:thread] = Thread.current
            start =  Time.now
            begin
              if ! active.include? fullname or ! aline or ! aline[:ip]
                server = start_server fullname, scope, flavor, @curlocation, curthread
                if ! server
                  delthread curthread        
                  return
                end
                server[:created_at] = Time.now
              else
                server = aline
                server[:created_at] = nil
                ssh_remove_ip server[:ip]
              end
              scope[:server] = server
              server[:started_at] = curthread[:started_at]
              if server[:ip]
                curthread[:state] = 'running'
                block.call({action: 'running', name: fullname, scope: scope, flavor: flavor, id: server[:id], ip: server[:ip], runtime: Time.now-curthread[:started_at]}) if block
                if server[:created_at] and @autodelete
                  log "#{fullname}: deleting..."
                  curthread[:state] = 'deleting'
                  delete_server(fullname, server[:id], @curlocation, flavor)
                end
              end
            rescue Exception => e
              log "#{fullname} #{curthread[:state]}: caught error with server start: #{e.message}" 
              log e.backtrace.join "\n"
            end
            delthread curthread        
          }
          @mutex.synchronize do 
            @threads.push curthread unless curthread[:dead]
          end
          waitthreads @maxjobs
        else
          alines.each do |aline|
            if @mode == 'fulllist'
              puts sprintf("#{@curlocation}\t%-20s\t#{aline[:id]}\t#{aline[:state]}", aline[:name])
            elsif aline[:name] == fullname
              if @mode == 'delete'
                start = Time.now
                puts delete_server(fullname, aline[:id], @curlocation, flavor)
                block.call({action: 'deleted', name: fullname, scope: scope, flavor: flavor, id: aline[:id], ip: aline[:ip], runtime: Time.now-start}) if block
              elsif @mode == 'list'
                puts sprintf("#{@curlocation}\t%-20s\t#{aline[:id]}\t#{aline[:state]}", fullname)
              end
            end
          end
          return if @mode == 'fulllist'
        end
      end	     
      waitthreads 0
      # XXX need to deal with maxjobs...
      if @mode == 'run' and ! @aborted
        log "Checking for new nodes to be provisioned..."
        object['compute_scopes'].each do |scope|
          break if @aborted          
          set_driver object, scope
          server = scope[:server]
          next unless server
          host = server[:ip]
          next if host.blank?
          id = server[:id]
          flavor = flavordefaults scope
          fullname = fullinstname scope
          curthread = {started_at: server[:started_at], fullname: fullname, inst: scopename(scope), loc: @curlocation, state: 'provisioning'}
          curthread[:thread] = Thread.new {
            begin
              curthread[:thread] = Thread.current
              if ! flavor['provisioning'].blank? and (@curprovider == 'host' or server[:created_at])
                log "Provisioning #{fullname} with #{flavor['provisioning']}"
                case flavor['provisioning']
                when 'chef'
                  begin 
                    ChefDriver.bootstrap(host, fullname, provisioning_tags(scope), flavor, @curlocation, @driver.config(@curlocation) )
                  rescue  Exception => e
                    puts "chef err: #{e.message}"
                    puts e.backtrace.join "\n"
                  end
                end
              end
              log "#{fullname}: provisioning done."
              curthread[:state] = "ready"
              block.call({action: 'ready', name: fullname, scope: scope, flavor: flavor, id: id, ip: host, runtime: Time.now-curthread[:started_at]}) if block
              delthread curthread
            rescue Exception => e
              puts "provisioning error: #{e.message}"
              puts e.backtrace.join "\n"
            end
          }
          @mutex.synchronize do 
            @threads.push curthread unless curthread[:dead]
          end            
        end
        waitthreads 0
      end
    rescue Exception => e
      puts "ObjDriver: #{e.class} #{e.message} ***"      
      log "\n\n**ObjDriver: #{e.class} #{e.message} ***"      
      log e.backtrace.join "\n" if e.class != Interrupt
      log "   threads: #{@threads.inspect}"
      @aborted = true      
    end
    @watchdog.kill if @watchdog
    if @mode == 'run'
      cleanup
      if @errorinsts.length > 0
        @errorinsts.uniq!
        log "instances that didn't complete: #{@errorinsts.join(',')}"
      end
      log "\033[1m#{@curprovider}/#{@curlocation} done at #{Time.now}; #{((Time.now-@started_at)/60).round} minutes\033[0m"
    else
      killall if @aborted
      log "\033[1m#{@curprovider}/#{@curlocation} #{@aborted ? 'aborted' : 'done'}\033[0m"
    end
  end

  def provisioning_tags scope
    tags = []
    return tags unless scope['tags']
    return tags unless @tags
    scope['tags'].each do |tag|
      @tags.each do |ptag|
        if ptag['name'] == tag['name'] and ptag['tag_type'] == 'provisioning'
          tags.push tag['name']
          break
        end
      end
    end
    tags
  end

  def verbose= n
    @verbose = n
  end

  def set_driver object, scope
    if scope['flavor'] and scope['flavor']['provider']
      prov = scope['flavor']['provider'] 
    else
      prov = object['provider']['cloud_driver']
    end    
    prov = 'host' if prov.nil?
    require_relative 'drivers/'+prov
    @driver = (prov.camelize+'Driver').constantize
    @driver.verbose = @verbose - 1
    @curprovider = prov
  end

  def waitthreads maxpending
    log "\033[1mStart waiting for #{@threads.length} threads: #{@threads.inspect}\033[m" if @threads.length > maxpending
    
    while @threads.length > maxpending
      @mutex.synchronize do 
        @threads.each_with_index do |t, idx|
          if t[:dead] or ! t[:thread].status
            if t[:thread].nil?
              log "run thread died from a hatchet wound: #{t.inspect}"
            end
            @threads.delete_at idx
            next
          end
          log "waiting for #{t[:fullname]} to finish" if @verbose > 0
        end
      end
      STDOUT.flush
      sleep 10
    end
  end

  def scopename scope
    scope['details'] || 'compute-'+scope['id']
  end


  def perfrun scope, flavor, ip, cretime=nil
    cmd = "(./RunRemote -I '#{scopename(scope)}' -O '#{scope['id']}' -i '#{File.expand_path flavor['keyfile']}' -H '#{@app_host}' -K #{APP_KEY} -S #{APP_SECRET} --create-time #{cretime} #{flavor['login_as']}@#{ip})  >> #{logfile} 2>&1"
    log "cmd=#{cmd}" if @verbose > 0
    IO.popen cmd do |fd|
      fd.each do |line|
        log line if @verbose > 0
      end
    end
  end

  def start_server fullname, scope, flavor, locflavor, curthread
    log "creating #{fullname}..."
    curthread[:state] = 'starting'
    server = create_server(fullname, scope, flavor, locflavor)
    if server.nil?
      log "#{fullname}: didn't start"
      @errorinsts.push "#{fullname} didn't start"
      return nil
    end
    log "Running created #{fullname} ip=#{server[:ip]}"
    ssh_remove_ip server[:ip]
    cmd = nil
    if server[:pass]
      log "#{fullname}: injecting public key..."
      curthread[:state] = 'injectpub'
      cmd = "sshpass -p #{server[:pass]} ssh #{SSHOPTS} #{flavor['login_as']}@#{server[:ip]} 'mkdir -p .ssh; chmod 0700 .ssh; echo \"#{@pubkey}\" >> .ssh/authorized_keys'"
    elsif @testconnection
      log "#{fullname}: testing connection..."
      curthread[:state] = 'conntest'
      cmd = "ssh #{SSHOPTS} -i #{File.expand_path flavor['keyfile']} #{flavor['login_as']}@#{server[:ip]} 'ls'"
    end
    if cmd
      ntry = 0
      while ntry < CONNECTRETRY
        break if system (cmd)
        ntry += 1
        log "#{fullname}: connect retry #{ntry}"
        sleep CONNECTRETRYTMO
      end
      if ntry >= CONNECTRETRY
        log " #{fullname}: can't connect"
        @errorinsts.push "#(fullname} (can't connect)"
        return nil
      end
    end
    return server
  end

  def status
    status = ""
    if @threads.length > 0
      status += "   running  "
      @threads.each do |t|
        status += "#{t[:fullname]}/#{t[:state]} "
      end
      status += "\n"
    end
    status = "nothing running...\n" if status.empty?
    status
  end

  def delthread thread
    @mutex.synchronize do 
      thread[:dead] = true
      @threads.each_with_index do |t, idx|
        next if t != thread
        @threads.delete_at idx
        break
      end
    end
  end

  def watchdog
    return if @watchdog
    @watchdog = Thread.new {
      while true        
        begin
          if @verbose > 0
            log "ObjDriver WD: threads=#{@threads.inspect}" 
          end
          now = Time.now
          @mutex.synchronize do
            @threads.each_with_index do |cur, idx|
              next if cur[:dead]
              if (now - cur[:started_at] > WATCHDOGTMO)
                log "WATCHDOG: killing #{cur[:fullname]} because create server didn't complete (#{(now-cur[:started_at]).round} seconds)"
                begin
                  cur[:thread].kill if cur[:thread]
                rescue
                end
                @errorinsts.push "#{cur[:fullname]} (create timed out)"
                @threads.delete_at idx
                cur[:dead] = true
              end
            end
          end
        rescue Exception => e
          log "WATCHDOG Exception: #{e.message}"
          log "#{e.backtrace.join "\n"}"
        end
        sleep 60
        STDOUT.flush
      end
    }
  end

  def ssh_remove_ip ip
    system "ssh-keygen -f ~/.ssh/known_hosts -R #{ip} >>#{logfile} 2>&1"
  end

  def abort
    @aborted = true
    killall
  end

  def killall    
    log "killall called for #{@curprovider}/#{@curlocation} t=#{@threads.length}" if @verbose > 0
    @threads.each do |t|
      next if t[:dead]
      begin
        t[:thread].kill
        log "#{@curprovider}/#{@curlocation} killing thread #{t[:thread]}" if @verbose > 0
      rescue Exception => e
        log "thread error: #{e.message}"
        end
    end
    @threads = []
  end

  def cleanup
    log "cleanup called for #{@curprovider}/#{@curlocation}"
    killall
    if @mode == 'run' and @autodelete
      opts = @opts.clone
      opts[:mode] = 'delete'
      r = self.class.new
      r.run opts
    end
    system "reset -I 2>/dev/null"
  end

  # driver related calls

  def create_server name, scope, flavor, location
    @driver.create_server name, scope, flavor, location
  end
 

  def delete_server name, id, location, flavor
    @driver.delete_server name, id, location, flavor
    if flavor['provisioning'] == 'chef'
      ChefDriver.delete_node(name) 
    end    
  end

  def get_active location, all, &block
    @driver.get_active location, all, &block
  end

  def flavordefaults scope
    @driver.flavordefaults scope
  end

  def fullinstname scope
    rv = scopename(scope)
    if @autodelete and @curprovider != 'host'
      rv += '-'+(@curlocation || 'no-location')
    end
    rv.gsub(/[ \/]/, '-')
  end

  def maxjobs
    @driver::MAXJOBS
  end

  def login_as
    @driver::LOGIN_AS || 'root'
  end


  def log msg
    begin
      File.write logfile, msg+"\n", mode: 'a'
    rescue
    end
  end

  def logfile
    "logs/#{@driver::CHEF_PROVIDER}.log"
  end

end

