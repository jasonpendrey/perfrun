require 'tempfile'
require 'json'
require_relative 'drivers/provider'
require_relative 'drivers/provisioning'
require_relative 'drivers/chef'


class ObjDriver
  WATCHDOGTMO = 30*60       # for running
  SSHOPTS = "-o LogLevel=quiet -oStrictHostKeyChecking=no"
  CONNECTRETRY = 20
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
    objprovider = object['provider']['name']
    @objlocation = object['provider']['location_flavor'] || object['provider']['address'] || '--no location--'
    @started_at = Time.now if @mode == 'run'
    @app_host = opts[:app_host] if opts[:app_host]
    @proxy = opts[:proxy] if opts[:proxy]
    @errorinsts = [] if @mode == 'run'
    @threads = []
    @mutex = Mutex.new
    watchdog
    @actives = {}
    sentbanner = false
    toprovision = []
    instances = {}
    begin
      object['compute_scopes'].each do |scope|
        break if @aborted
        next if @targscopes and ! @targscopes.include? scopename(scope)
        driver = get_driver object, scope
        if @mode == 'run' and ! sentbanner
          log "Running #{object['name']}@#{driver[:provider]}/#{@objlocation} to #{@app_host}" 
          sentbanner = true
        end
        flavor = driver[:driver].flavordefaults scope
        next if flavor.nil?
        @maxjobs = opts[:maxjobs] || driver[:driver]::MAXJOBS
        provloc = driver[:provider]+@objlocation
        if @actives[provloc].nil?          
          active = {}
          alines = []
          driver[:driver].get_active @objlocation, @mode != 'run' do |id, name, ip, state|
            active[name] = name
            alines.push({id: id, name: name, ip: ip, state: state})
          end
          active = active.values
          @actives[provloc] = {active: active, alines: alines}
        else
          alines = @actives[provloc][:alines]
          active = @actives[provloc][:active]
        end
        fullname = fullinstname scope, driver[:provider]
        log "Running #{fullname}..." if @mode == 'run'
        aline = nil
        alines.each do |a|
          next if a[:name] != fullname
          aline = a
          break
        end
        if @mode == 'run'
          pubkey = `ssh-keygen -y -f #{File.expand_path flavor['keyfile']}`
          raise "can't access #{flavor['keyfile']}" if pubkey.nil? or pubkey.empty?
          curthread = {started_at:Time.now, fullname: fullname, inst: scopename(scope), loc: @objlocation, state: 'starting'}
          curthread[:thread] = Thread.new {
            curthread[:thread] = Thread.current
            begin
              if ! active.include? fullname or ! aline or ! aline[:ip]
                server = start_server driver, fullname, scope, flavor, @objlocation, curthread, pubkey
                if ! server
                  delthread curthread        
                  Thread.exit
                end
                server[:created_at] = Time.now
              else
                server = aline
                server[:created_at] = nil
                log "reusing #{fullname} #{server[:ip]}"
                ssh_remove_ip server[:ip]
              end
              server[:started_at] = curthread[:started_at]
              if server[:ip]
                curthread[:state] = 'running'
                block.call({action: 'running', name: fullname, scope: scope, flavor: flavor, id: server[:id], ip: server[:ip], runtime: Time.now-curthread[:started_at]}) if block
                if server[:created_at] and @autodelete
                  if driver[:provider] != 'host'
                    log "#{fullname}: deleting..."
                    curthread[:state] = 'deleting'
                    driver[:driver].delete_server(fullname, server[:id], @objlocation, flavor)
                    if flavor['provisioning'] == 'chef'
                      ChefDriver.delete_node(fullname) 
                    end    
                  end
                else
                  toprovision.push({scope: scope, server: server})
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
            next if instances[aline[:id]]
            if @mode == 'fulllist' or aline[:name] == fullname
              instances[aline[:id]] = true
              if @mode == 'delete' or @mode == 'cleanup'
                start = Time.now
                puts "deleting #{fullname}/#{aline[:id]}" if @mode == 'delete'
                driver[:driver].delete_server(fullname, aline[:id], @objlocation, flavor)
                if flavor['provisioning'] == 'chef'
                  ChefDriver.delete_node(fullname) 
                end    
                block.call({action: 'deleted', name: fullname, scope: scope, flavor: flavor, id: aline[:id], ip: aline[:ip], runtime: Time.now-start}) if block
              else
                puts sprintf("#{@objlocation}\t%-20s\t#{aline[:id]}\t#{aline[:ip]}\t#{aline[:state]}", aline[:name])
              end
            end
          end
        end
      end
      waitthreads
      if @mode == 'run' and ! @aborted and toprovision.length > 0
        log "Checking for new nodes to be provisioned..."
        toprovision.each do |ent|          
          break if @aborted          
          scope = ent[:scope]
          server = ent[:server]
          next unless server
          driver = get_driver object, scope
          host = server[:ip]
          next if host.blank?
          id = server[:id]
          flavor = driver[:driver].flavordefaults scope
          fullname = fullinstname scope, driver[:provider]
          curthread = {started_at: server[:started_at], fullname: fullname, inst: scopename(scope), loc: @objlocation, state: 'provisioning'}
          curthread[:thread] = Thread.new {
            begin
              curthread[:thread] = Thread.current
              if ! flavor['provisioning'].blank? and (driver[:provider] == 'host' or server[:created_at])
                log "Provisioning #{fullname} with #{flavor['provisioning']}"
                case flavor['provisioning']
                when 'chef'
                  begin 
                    ChefDriver.bootstrap(host, fullname, provisioning_tags(scope), flavor, @objlocation, driver[:driver].config(@objlocation) )
                  rescue  Exception => e
                    puts "chef err: #{e.message}"
                    puts e.backtrace.join "\n"
                  end
                end
                log "#{fullname}: provisioning with #{flavor['provisioning']} done."
              end
              log "#{fullname}: ready."              
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
          waitthreads @maxjobs
        end
      end
      waitthreads
    rescue Exception => e
      puts "ObjDriver: #{e.class} #{e.message} ***"      
      puts e.backtrace.join "\n" if e.class != Interrupt
      log "\n\n**ObjDriver: #{e.class} #{e.message} ***"      
      log e.backtrace.join "\n" if e.class != Interrupt
      log "   threads: #{@threads.inspect}"
      @aborted = true      
    end
    @watchdog.kill if @watchdog
    if @mode == 'run'
      waitthreads
      cleanup if @autodelete
      if @errorinsts.length > 0
        @errorinsts.uniq!
        log "instances that didn't complete: #{@errorinsts.join(',')}"
      end
      log "\033[1m#{objprovider}/#{@objlocation} done at #{Time.now}; #{((Time.now-@started_at)/60).round} minutes\033[0m"
    else
      killall if @aborted
      log "\033[1m#{objprovider}/#{@objlocation} #{@aborted ? 'aborted' : 'done'}\033[0m"
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

  def get_driver object, scope
    if scope['flavor'] and scope['flavor']['provider']
      prov = scope['flavor']['provider'] 
    else
      prov = object['provider']['cloud_driver']
    end    
    prov = 'host' if prov.blank?
    begin
      require_relative 'drivers/'+prov
      driver = Object.const_get (prov.camel_case+'Driver')
    rescue Exception => e
      if scope['flavor'] and scope['flavor']['provider']
        puts "error loading flavor driver: #{prov}: #{e.message}"
      else
        puts "error loading provider driver: #{prov}: #{e.message}"
      end    
      exit 1
    end
    driver.verbose = @verbose - 1
    @curdriver = driver
    @curprovider = prov
    { driver: driver, provider: prov } 
  end

  def waitthreads maxpending=nil
    maxpending = 1 if maxpending.nil?
    
    log "\033[1mStart waiting for #{@threads.length} threads: #{threadlist}\033[m" if @threads.length > maxpending    
    while @threads.length >= maxpending
      return if @aborted
      @mutex.synchronize do 
        @threads.each_with_index do |t, idx|
          if t[:dead] or ! t[:thread].status
            if t[:thread].nil?
              log "run thread died from a hatchet wound: #{t.inspect}"
            end
            @threads.delete_at idx
            next
          end
          log "waiting for #{t[:fullname]}: #{t[:state]}" if @verbose > 0
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
    if @proxy
      proxy = "-x '#{@proxy}'"
    else
      proxy = ''
    end
    cmd = "(./RunRemote -I '#{scopename(scope)}' -O '#{scope['id']}' -i '#{File.expand_path flavor['keyfile']}' -H '#{@app_host}' -K #{APP_KEY} -S #{APP_SECRET} #{proxy} --create-time #{cretime} --port #{flavor['sshport']} #{flavor['login_as']}@#{ip})  >> #{logfile} 2>&1"
    log "cmd=#{cmd}" if @verbose > 0    
    for i in 0..1 do
      break if @aborted
      rv = nil
      IO.popen cmd do |fd|
        begin
          fd.each do |line|
            log line if @verbose > 0
          end
        ensure
          fd.close
          rv = $?
        end
      end
      return if rv.exitstatus.to_i == 0
      sleep 60
      log "RunRemote: retry ##{i+1} $?=#{rv.inspect}"
    end
    log "RunRemote: exhausted all retries. giving up."
  end

  def start_server driver, fullname, scope, flavor, locflavor, curthread, pubkey
    log "creating #{fullname}..."
    curthread[:state] = 'starting'
    server = driver[:driver].create_server(fullname, scope, flavor, locflavor)
    if server.nil?
      log "#{fullname}: didn't start"
      @errorinsts.push "#{fullname} didn't start"
      return nil
    end
    log "Running created #{fullname} ip=#{server[:ip]}"
    ssh_remove_ip server[:ip]
    cmd = nil
    done = '__DoneIsDoneDiddlyDoneDone__'
    if server[:pass]
      log "#{fullname}: injecting public key..."
      curthread[:state] = 'injectpub'
      cmd = "sshpass -p #{server[:pass]} ssh #{SSHOPTS} -p #{flavor['sshport']} #{flavor['login_as']}@#{server[:ip]} 'mkdir -p .ssh; chmod 0700 .ssh; echo \"#{pubkey}\" >> .ssh/authorized_keys; echo \"#{done}\"'"
    else
      curthread[:state] = 'conntest'
      cmd = "ssh #{SSHOPTS} -p #{flavor['sshport']} -i #{File.expand_path flavor['keyfile']} #{flavor['login_as']}@#{server[:ip]} 'echo \"#{done}\"'"
    end
    ntry = 0
    log "#{fullname}: testing #{server[:ip]} connection..."
    while ntry < CONNECTRETRY
      break if @aborted
      out = `#{cmd} 2>/dev/null`
      log "#{server[:ip]} conntest='#{out}'" if @verbose > 0
      break if out.end_with? done+"\n"
      ntry += 1
      log "#{fullname}: connect retry #{ntry}"
      sleep CONNECTRETRYTMO
    end
    if ntry >= CONNECTRETRY
      log " #{fullname}: can't connect"
      @errorinsts.push "#{fullname} (can't connect)"
      return nil
    end
    return server
  end

  def status
    status = ""
    if @threads.length > 0
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
    log "aborting #{@curprovider}/#{@objlocation}..."
    @aborted = true
    killall
  end

  def killall    
    log "killall called for #{@curprovider}/#{@objlocation} t=#{@threads.length}" if @verbose > 0 and @threads.length > 0
    @threads.each do |t|
      next if t[:dead]
      begin
        t[:thread].kill
        log "#{@curprovider}/#{@objlocation} killing thread #{t[:thread]}" if @verbose > 0
      rescue Exception => e
        log "thread error: #{e.message}"
        end
    end
    @threads = []
  end

  def cleanup
    return if @cleaning
    @cleaning = true
    log "cleanup called for #{@curprovider}/#{@objlocation}"
    killall    
    if @mode == 'run' and @autodelete
      opts = @opts.clone
      opts[:mode] = 'cleanup'
      r = self.class.new
      r.run opts
    end
    system "reset -I 2>/dev/null"
  end

  def fullinstname scope, provider
    rv = scopename(scope)
    if @autodelete and provider != 'host'
      rv += '-'+(@objlocation || 'no-location')
    end
    # make dns friendly names
    rv.gsub(/[ \/_]/, '-')
  end

  # driver related calls

  def log msg
    begin
      @curdriver.log msg
    rescue
    end
  end

  def logfile
    @curdriver.logfile
  end

  def threadlist
    rv = ''
    @threads.each do |t|
      rv += " (#{t[:prov]}/#{t[:loc]}: #{t[:fullname]} #{t[:state]})"
    end
    rv 
  end

end

class String
  def camel_case
    return self if self !~ /_/ && self =~ /[A-Z]+.*/
    split('_').map{|e| e.capitalize}.join
  end
end

class Object
  def blank?
    respond_to?(:empty?) ? !!empty? : !self
  end
end
