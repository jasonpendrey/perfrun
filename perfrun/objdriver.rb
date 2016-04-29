require 'active_support/all'  # for camelize
require_relative 'drivers/provider'
require_relative 'drivers/provisioning'
require_relative 'drivers/chef'


class ObjDriver
  WATCHDOGTMO = 30*60       # for running
  SSHOPTS = "-o LogLevel=quiet -oStrictHostKeyChecking=no"
  CONNECTRETRY = 10
  CONNECTRETRYTMO = 10

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
    @verbose = opts[:verbose] || 0
    @autodelete = opts[:autodelete]    
    @testconnection = opts[:test_connection]
    @curprovider = object['provider']['name']
    @curlocation = object['provider']['location_flavor'] || object['provider']['address']
    require_relative 'drivers/'+(object['provider']['cloud_driver'] || 'host')
    @driver = ((object['provider']['cloud_driver'] || 'host').camelize+'Driver').constantize
    # no driver verbose mode in perfrun mode... too noisy 
    @driver.verbose = @verbose - 1
    if @mode == 'run'
      @started_at = Time.now
    end
    @app_host = opts[:app_host] if opts[:app_host]
    @errorinsts = [] if @mode == 'run'
    @threads = []
    @mutex = Mutex.new
    watchdog
    log "Perfrun for #{object['name']}@#{@curprovider}/#{@curlocation} to #{@app_host}" if @mode == 'run'
    begin
      active = {}
      alines = []
      get_active @curlocation, @mode != 'run' do |id, name, ip, state|
        active[name] = name
        alines.push({id:id, name:name, ip:ip, state: state})
      end
      active = active.values
      fetchedactive = true
      object['compute_scopes'].each do |scope|
        break if @aborted
        flavor = scope['flavor']
        next if flavor.nil?
        if scope['id'].nil?
          log "ignoring null objective for #{@curprovider}"
          next
        end
        flavor['login_as'] = login_as if flavor['login_as'].blank?
        unless flavor['keyfile'].blank?
          if ! flavor['keyfile'].include?('/') and ! flavor['keyfile'].include?('..')
            flavor['keyfile'] = "#{Dir.pwd}/config/#{flavor['keyfile']}"
          end
        else
          flavor['keyfile'] = "#{Dir.pwd}/config/servers.pem"
        end
        fullname = fullinstname scope, @curlocation
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
            ip = id = nil
            begin
              if ! active.include? fullname or ! aline or ! aline[:ip]
                server = start_server fullname, scope, @curlocation, curthread
                if server
                  ip = server[:ip]
                  id = server[:id]
                  curthread[:created] = true
                  scope[:server] = server
                end
              else
                ip = aline[:ip]
                id = aline[:id]
                ssh_remove_ip ip
                curthread[:created] = false
              end
              if ip
                curthread[:state] = 'running'
                block.call({name: fullname, scope: scope, flavor: flavor, id: id, ip: ip, cretime: Time.now-start}) if block
                if curthread[:created] and @autodelete
                  log "#{fullname}: deleting..."
                  curthread[:state] = 'deleting'
                  delete_server(fullname, id, @curlocation, flavor)
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
          waitthreads maxjobs
        else
          alines.each do |aline|
            if aline[:name] == fullname
              if @mode == 'delete'
                # XXX want to use threads here, but need to keep track of them to wait before exit
                puts delete_server(fullname, aline[:id], @curlocation, flavor)
              elsif @mode == 'list'
                puts sprintf("#{@curlocation}\t%-20s\t#{aline[:id]}\t#{aline[:state]}", fullname)
              end
            end
            if @mode == 'knifelist'
              puts sprintf("#{@curlocation}\t%-20s\t#{aline[:id]}\t#{aline[:state]}", aline[:name])
            end
          end
          return if @mode == 'knifelist'
        end
      end	     
      waitthreads 0
      if @mode == 'run'
        log "Checking for new nodes to be provisioned..."
        object['compute_scopes'].each do |scope|
          break if @aborted
          next if scope[:server].nil?
          flavor = scope['flavor']
          fullname = fullinstname scope, @curlocation
          unless flavor['provisioning'].blank?
            curthread = {started_at:Time.now, fullname: fullname, inst: scopename(scope), loc: @curlocation, state: 'provisioning'}
            curthread[:thread] = Thread.new {
              curthread[:thread] = Thread.current
              log "Provisioning #{fullname} with #{flavor['provisioning']}"
              case flavor['provisioning']
              when 'chef'
                begin 
                  ChefDriver.bootstrap(scope[:server][:ip], fullname, provisioning_tags(scope), flavor, @curlocation, @driver.config(@curlocation) )
                rescue  Exception => e
                  puts "chef err: #{e.message}"
                end
              end              
              log "provisioning done."
              curthread[:state] = "provisioningdone"
              delthread curthread
            }
            @mutex.synchronize do 
              @threads.push curthread unless curthread[:dead]
            end
          end
        end
        waitthreads 0
      end

    rescue Exception => e
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
      log "\033[1mPerfrun #{@curprovider}/#{@curlocation} done at #{Time.now}; #{((Time.now-@started_at)/60).round} minutes\033[0m"
    else
      killall if @aborted
      log "\033[1mPerfrun #{@curprovider}/#{@curlocation} #{@aborted ? 'aborted' : 'done'}\033[0m"
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

  def start_server fullname, scope, locflavor, curthread
    flavor = scope['flavor']
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

  def fullinstname scope, locflavor
    rv = scopename(scope)
    if @autodelete
      rv += '-'+(locflavor || 'no-location')
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

