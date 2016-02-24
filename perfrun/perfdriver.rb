require 'optparse'
require './dblog'
require 'active_support/all'  # for camelize

class PerfDriver
  WATCHDOGTMO = 10*60       # for creation
  WATCHDOGTMO2 = 30*60      # for running tests
  SSHOPTS = "-o LogLevel=quiet -oStrictHostKeyChecking=no"

  def initialize
    Dir["./drivers/*.rb"].each {|file| require file }
    @threads = []
    @pids = []
    @verbose = 0
  end

  def run opts 
    @ident = "#{Dir.pwd}/config/servers.pem"
    @app_host = $apphost || APP_HOST
    @opts = opts
    @aborted = false
    DbLog.initdb if @withdb
    instances = opts[:instances]
    @mode = opts[:mode]    
    @curprovider = instances[0]['provider']
    @curlocation = instances[0]['location']
    @driver = (@curprovider.camelize+'Driver').constantize
    @login_as = login_as
    if @mode == 'run'
      @started_at = Time.now
      begin
        DbLog.run_started
        DbLog.run_status @provider, "runstart", "Starting run for #{instances}" 
      rescue Exception => e
        puts "dblog error: #{e.message}"
        puts e.backtrace.join "\n"
      end
    end
    @app_host = opts[:app_host] if opts[:app_host]
    @errorinsts = [] if @mode == 'run'
    @pids = []
    @threads = []
    @mutex = Mutex.new
    @jobwait = 0 
    watchdog
    log "Perfrun for #{@curprovider}/#{@curlocation} to #{@app_host}" if @mode == 'run'
    begin
      activeloc = nil
      activeprovider = nil      
      active = {}
      alines = []
      instances.each do |inst|
        break if @aborted
        @maxjobs = maxjobs
        @curprovider = inst['provider']
        instloc = inst['location']
        instname = inst['instname']
        flavor = inst['flavor'] || inst['instname']
        scope_id = inst['objective']
        if instloc.nil?
          log "ignoring null location for #{@curprovider}"
          next
        end
        if scope_id.nil?
          log "ignoring null objective for #{@curprovider}"
          next
        end
        if instname.nil?
          log "ignoring null instname for #{@curprovider}"
          next
        end
        @login_as = inst['login_as'] if inst['login_as']
        if inst['keyfile']
          if inst['keyfile'].include? '/' or inst['keyfile'].include? '..'
            @ident = inst['keyfile']
          else
            @ident = "#{Dir.pwd}/config/#{inst['keyfile']}"
          end
        end
        fullname = fullinstname instname, instloc          
        if (! activeloc or activeloc != instloc or ! activeprovider or activeprovider != @curprovider)
          active = {}
          alines = []
          get_active instloc, @mode != 'run' do |id, name, ip, state|
            active[name] = name
            alines.push({id:id, name:name, ip:ip, state: state})
          end
          active = active.values          
          activeloc = instloc
          activeprovider = @curprovider
        end
        aline = nil
        alines.each do |a|
          next if a[:name] != fullname
          aline = a
          break
        end
        if @mode == 'run'
          @pubkey = `ssh-keygen -y -f #{@ident}`
          raise "can't access #{@ident}" if @pubkey.nil? or @pubkey.empty?
          if ! active.include? fullname or ! aline or ! aline[:ip]
            next unless start_server fullname, instname, flavor, instloc, scope_id
          else
            ssh_remove_ip aline[:ip]
            cmd = "(echo 'logging into #{fullname}...' && ./RunRemote  -O '#{scope_id}' -I '#{instname}' -i '#{@ident}' -H '#{@app_host}' -K #{APP_KEY} -S #{APP_SECRET} #{@login_as}@#{aline[:ip]}) >> #{logfile} 2>&1"
            @mutex.synchronize do 
              @pids.push({pid: spawn(cmd), inst: instname, loc: instloc, started_at: Time.now})
            end
          end
          if @threads.length >= @maxjobs
            waitthreads
          end
          if @pids.length >= @maxjobs
            waitpids
          end
        else
          alines.each do |aline|
            if aline[:name] == fullname
              if @mode == 'delete'
                cmd = delete_server(fullname, aline[:id], instloc)
                @mutex.synchronize do 
                  @pids.push({pid: spawn(cmd+'||true'), inst: fullname, loc: instloc, started_at: Time.now})
                end
              elsif @mode == 'list'
                puts sprintf("#{instloc}\t%-20s\t#{aline[:id]}\t#{aline[:state]}", fullname)
              end
            end
            if @mode == 'knifelist'
              puts sprintf("#{instloc}\t%-20s\t#{aline[:id]}\t#{aline[:state]}", aline[:name])
            end
          end
          return if @mode == 'knifelist'
        end
      end	     
      waitthreads
      waitpids
    rescue Exception => e
      log "\n\n***Perfdriver: cleaning up because of #{e.inspect} ***"
      log e.backtrace.join "\n"
      log " threads: #{@threads.inspect}"
      log " pids: #{@pids.inspect}"
      log " wd: #{@watchdog.inspect}"
      @aborted = true
      
      @watchdog.kill if @watchdog
      if @mode == 'run'
        cleanup
        if @errorinsts.length > 0
          @errorinsts.uniq!
          log "instances that didn't complete: #{@errorinsts.join(',')}"
          DbLog.run_status @provider, "errinst", "#{@errorinsts.join(',')}" 
        end
        log "\033[1mRun aborted for #{instances}\033[m" 
        DbLog.run_status @provider, "runabort", "Run aborted for #{instances}" 
      else
        killall
      end
      exit 1
    end
    @watchdog.kill if @watchdog
    if @mode == 'run'
      cleanup
      if @errorinsts.length > 0
        @errorinsts.uniq!
        log "instances that didn't complete: #{@errorinsts.join(',')}"
        DbLog.run_status @provider, "errinst", "#{@errorinsts.join(',')}" 
      end
      log "\033[1mPerfrun #{@curprovider}/#{@curlocation} done at #{Time.now}; #{((Time.now-@started_at)/60).round} minutes\033[0m"
      DbLog.run_status @provider, "rundone", "Run done for #{instances}" 
    end
  end

  def verbose n
    @verbose = n
  end

  def waitthreads
    log "\033[1mStart waiting for #{@threads.length} threads: #{@threads.inspect}\033[m" if @threads.length > 0
    while @threads.length > 0
      @mutex.synchronize do 
        @threads.each_with_index do |t, idx|
          if t[:dead]
            @threads.delete_at idx
            next
          end
          log "waiting for #{t[:fullname]} to start" if @verbose > 0
        end
      end
      STDOUT.flush
      sleep 10
    end
  end

  def waitpids
    log "\033[1mwaiting for #{@pids.inspect}\033[m" if @pids.length > 0
    while @pids.length > 0
      log "Run: waiting for #{@pids.inspect}" if @verbose > 0
      @mutex.synchronize do 
        @pids.each_with_index do |pid, idx|
          begin
            Process.wait(pid[:pid], Process::WNOHANG)
          rescue Errno::ECHILD
            log "deleting #{pid.inspect}" if @verbose > 0
            @pids.delete_at idx
            DbLog.inst_status "server_done", "#{pid[:inst]}-#{pid[:loc]}", pid[:inst], nil
            next
          end
          if pid[:timedout]
            log "deleting #{pid.inspect} even though it is timed out"
            @pids.delete_at idx
          end
        end
      end
      STDOUT.flush
      sleep 10
    end
    @jobwait = 0
  end

  def start_server fullname, instname, flavor, instloc, scope_id
    log "creating #{fullname}/#{instname}..."
    crestart = Time.now
    DbLog.inst_status "server_start", "starting #{fullname}", instname, crestart
    out = nil
    curthread = {started_at:Time.now, fullname: fullname, inst: instname, loc: instloc}
    curthread[:thread] = Thread.new {
      begin
        curthread[:thread] = Thread.current
        log "#{fullname}: waiting #{@jobwait*1}" if @jobwait > 0
        sleep @jobwait * 1
        @jobwait += 1
        out = create_server(fullname, flavor, instloc, @login_as, @ident)
        if out.nil?
          log "#{fullname} didn't start"
          @errorinsts.push "#(fullname} didn't start"
          delthread curthread        
          DbLog.inst_status "server_error", "#{fullname} didn't start", instname, crestart
          return false
        end
        cretime = Time.now-crestart
        log "create output: #{out}\nend output" if @verbose > 0
        pass = nil
        create_ip = nil
        create_id = nil
        diskuuid = nil
        error = nil
        out.split("\n").each do |line|
          if line.start_with? "Password: "
            pass = line.split(' ')[1]
          end
          if line.start_with? "Connecting to "
            create_ip = line.split(' ')[2]
          end
          if line.start_with? "Floating IP Address:"
            create_ip = line.split(' ')[3]
          end
          if line.start_with? "DISKUUID:"
            diskuuid = line.split(' ')[1]
          end
          if line.upcase.start_with? "ERROR:"
            error = line
          end
        end
        if error
          log "***an error occurred starting #{fullname}: #{error}"
          log "#{fullname}: create output: #{out}"
          @errorinsts.push "#{fullname} (create returned error)"
          delthread curthread
          DbLog.inst_status "server_error", "#{fullname} error: #{error}", instname, crestart
          return false
        end
        log "#{fullname}: password=#{pass.inspect}, createip: #{create_ip.inspect}, diskuuid: #{diskuuid.inspect}" if @verbose > 0
        found = false
        id = ip = nil
        actives = get_active instloc, false do |mid, mname, mip, mstate|      
          if mname == fullname
            id = mid
            ip = mip
            found = true
            break
          end
        end
        ip = create_ip if ip.nil?
        if ! found
          log "***something went wrong starting #{fullname}***"
          log "#{fullname}: create output: #{out}"
          log "#{fullname}: active: #{actives.inspect}"
          @errorinsts.push fullname
          delthread curthread
          DbLog.inst_status "server_error", "#{fullname} error: #{out}", instname, crestart
          return false
        end
        log "Running created #{fullname} ip=#{ip} id=#{id}"
        ssh_remove_ip ip
        if pass
          ntry = 0
          while ntry < 5
            break if system ("sshpass -p #{pass} ssh #{SSHOPTS} #{@login_as}@#{ip} 'mkdir -p .ssh; chmod 0700 .ssh; echo \"#{@pubkey}\" >> .ssh/authorized_keys'")
            log "retry #{ntry} insert pubkey to authkeys..."
            ntry += 1
            sleep 5
          end
          if ntry >= 5
            log "can't insert public key into #{fullname}"
            @errorinsts.push "#(fullname} (can't insert public key)"
            delthread curthread
            DbLog.inst_status "server_error", "#{fullname} error: can't insert public key", instname, crestart
            return false
          end
        end
        cmd = "(./RunRemote -I '#{instname}' -O '#{scope_id}' -i '#{@ident}' -H '#{@app_host}' -K #{APP_KEY} -S #{APP_SECRET} --create-time #{cretime} #{@login_as}@#{ip} && " +(delete_server(fullname, id, instloc, diskuuid))+ ")  >> #{logfile} 2>&1"
        log "cmd=#{cmd}" if @verbose > 0
        @mutex.synchronize do 
          @pids.push({pid: spawn(cmd), inst: instname, loc: instloc, started_at: Time.now})
        end
        delthread curthread
        DbLog.inst_status "server_started", "#{fullname} started", instname, crestart
      rescue => e
        log "caught error starting server #{fullname}: #{e.message}" 
        log e.backtrace.join "\n"
        delthread curthread
      end
    }
    @mutex.synchronize do 
      @threads.push curthread unless curthread[:dead]
    end
    return true
  end

  def status
    status = "   starting  "
    @threads.each do |t|
      status += "#{t[:inst]}/#{t[:loc]} "
    end
    status += "\n   running   "
    @pids.each do |p|
      status += "#{p[:inst]}/#{p[:loc]} "
    end
    status += "\n"
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
            log "Perfdriver WD: pids=#{@pids.inspect}"
            log "    threads=#{@threads.inspect}" 
          end
          now = Time.now
          @mutex.synchronize do
            @threads.each_with_index do |cur, idx|
              next if cur[:dead]
              if (now - cur[:started_at] > WATCHDOGTMO)
                log "WATCHDOG: killing #{cur[:inst]}-#{cur[:loc]} because create server didn't complete (#{(now-cur[:started_at]).round} seconds)"
                begin
                  cur[:thread].kill if cur[:thread]
                rescue
                end
                @errorinsts.push "#{cur[:inst]}-#{cur[:loc]} (create timed out)"
                @threads.delete_at idx
                cur[:dead] = true
                DbLog.inst_status "server_killed", "#{cur[:inst]}-#{cur[:loc]} start thread killed by watchdog", cur[:inst], nil
              end
            end
            @pids.each_with_index do |pid, idx|
              if (now - pid[:started_at] > WATCHDOGTMO2 and ! pid[:timedout])
                begin
                  begin
                    Process.getpgid pid[:pid]              
                  rescue Errno::ESRCH
                    next
                  end
                  begin
                    Process.kill "HUP", pid[:pid]
                  rescue Exeception => e
                    log "WATCHDOG error killing #{pid[:pid]} #{e.message}"
                  end
                  log "WATCHDOG-#{Process.pid}: killing #{pid[:inst]}-#{pid[:loc]}/#{pid[:pid]} because #{((now-pid[:started_at])/60).round} minutes have elapsed"
                  @errorinsts.push "#{pid[:inst]}-#{cur[:loc]} (timed out)"
                  @pids.delete_at idx
                  DbLog.inst_status "server_killed", "#{cur[:inst]}-#{cur[:loc]} run process killed by watchdog", cur[:inst], nil
                  pid[:timedout] = true
                rescue 
                end
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
    log "killall called for #{@curprovider}/#{@curlocation} t=#{@threads.length} p=#{@pids.length}" if @verbose > 0
    @threads.each do |t|
      next if t[:dead]
      begin
        t[:thread].kill
        log "#{@curprovider}/#{@curlocation} killing thread #{t[:thread]}" if @verbose > 0
        DbLog.inst_status "server_abort", "#t[:inst]}-#{t[:loc]} start thread killed by abort", t[:inst], nil
      rescue Exception => e
        log "thread error: #{e.message}"
        end
    end
    @threads = []
    @pids.each do |pid|
      begin
        Process.kill "HUP", pid[:pid]
        log "#{@curprovider}/#{@curlocation} killing pid #{pid[:pid]}" if @verbose > 0
        DbLog.inst_status "server_abort", "#{pid[:inst]}-#{pid[:loc]} run process killed by abort", pid[:inst], nil
      rescue
      end
    end
    @pids = []
  end

  def cleanup
    log "cleanup called for #{@curprovider}/#{@curlocation}"
    killall
    if @mode == 'run'
      opts = @opts.clone
      opts[:mode] = 'delete'
      r = self.class.new
      r.run opts
    end
    system "reset -I 2>/dev/null"
  end

  # driver related calls

  def create_server name, instance, location, login_as, ident
    @driver.create_server name, instance, location, login_as, ident
  end
 

  def delete_server name, id, location, diskuuid=nil
    @driver.delete_server name, id, location, diskuuid
  end

  def get_active location, all, &block
    @driver.get_active location, all, &block
  end

  def fullinstname instname, instloc
    if @driver.respond_to? :fullinstname
      @driver.fullinstname instname, instloc
    else
      instname+'/'+instloc
    end
  end

  def maxjobs
    @driver::MAXJOBS
  end

  def login_as
    @driver::LOGIN_AS || 'root'
  end

  def log msg
    File.write logfile, msg+"\n", mode: 'a'
    puts msg if @verbose  > 0
  end

  def logfile
    "logs/#{@driver::CHEF_PROVIDER}.log"
  end

end

