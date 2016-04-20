require 'optparse'
require 'active_support/all'  # for camelize

class SpinDriver
  WATCHDOGTMO = 30*60       # for creation
  WATCHDOGTMO2 = 30*60      # for running tests
  SSHOPTS = "-o LogLevel=quiet -oStrictHostKeyChecking=no"

  def initialize
    Dir["./drivers/*.rb"].each {|file| require file }
    @threads = []
    @pids = []
    @verbose = 0
  end

  def run opts 
    @app_host = $apphost || APP_HOST
    @opts = opts
    @aborted = false
    object = opts[:object]
    @tags = opts[:tags]
    @mode = opts[:mode]    
    @curprovider = object['provider']['name']
    @curlocation = object['provider']['location_flavor'] || object['provider']['address']
    @driver = ((object['provider']['cloud_driver'] || 'host').camelize+'Driver').constantize
    if @mode == 'run'
      @started_at = Time.now
    end
    @app_host = opts[:app_host] if opts[:app_host]
    @errorinsts = [] if @mode == 'run'
    @pids = []
    @threads = []
    @mutex = Mutex.new
    @jobwait = 0 
    watchdog
    begin
      active = {}
      alines = []
      log "Spining up #{object['name']} objectives..." if @mode == 'run'
      object['compute_scopes'].each do |scope|
        break if @aborted
        flavor = scope['flavor']
        next if flavor.nil?
        @maxjobs = maxjobs
        if scope['id'].nil?
          log "ignoring null objective for #{@curprovider}"
          next
        end
        if scope['details'].nil?
          log "ignoring null scope name for #{@curprovider}"
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
        log "Spining up #{fullname}..." if @mode == 'run'
        active = {}
        alines = []
        get_active @curlocation, @mode != 'run' do |id, name, ip, state|
          active[name] = name
          alines.push({id:id, name:name, ip:ip, state: state})
        end
        active = active.values          
        aline = nil
        alines.each do |a|
          next if a[:name] != fullname
          aline = a
          break
        end
        if @mode == 'run'
          @pubkey = `ssh-keygen -y -f #{flavor['keyfile']}`
          raise "can't access #{flavor['keyfile']}" if @pubkey.nil? or @pubkey.empty?
          if ! active.include? fullname or ! aline or ! aline[:ip]
            next unless start_server fullname, scope, @curlocation
          else
            log "#{fullname} already exists... skipping"
            next
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
                cmd = delete_server(fullname, aline[:id], @curlocation)
                @mutex.synchronize do 
                  @pids.push({pid: spawn(cmd+'||true'), fullname: fullname, inst: fullname, loc: @curlocation, started_at: Time.now})
                end
              elsif @mode == 'list'
                puts sprintf("#{@curlocation}\t%-20s\t#{aline[:id]}\t#{aline[:ip]}\t#{aline[:state]}", fullname)
              end
            end
            if @mode == 'knifelist'
              puts sprintf("#{@curlocation}\t%-20s\t#{aline[:id]}\t#{aline[:state]}", aline[:name])
            end
          end
          return if @mode == 'knifelist'
        end
      end	     
      waitthreads
      waitpids
    rescue Exception => e
      log "\n\n***Spindriver: cleaning up because of #{e.inspect} ***"
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
        end
        log "<b>Run aborted for #{objects}</b>" 
      else
        killall
      end
      exit 1
    end
    @watchdog.kill if @watchdog
    if @mode == 'run'
      #cleanup
      if @errorinsts.length > 0
        @errorinsts.uniq!
        log "instances that didn't complete: #{@errorinsts.join(',')}"
      end
      log "<b>Spinup #{@curprovider}/#{@curlocation} done at #{Time.now}; #{((Time.now-@started_at)/60).round} minutes</b>"
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

  def waitthreads
    log "<b>Start waiting for #{@threads.length} threads: #{@threads.inspect}</b>" if @threads.length > 0
    while @threads.length > 0
      @mutex.synchronize do 
        @threads.each_with_index do |t, idx|
          if t[:dead]
            @threads.delete_at idx
            next
          end
          log "waiting for #{t[:fullname]} to start" if @verbose > 1
        end
      end
      STDOUT.flush
      sleep 10
    end
  end

  def waitpids
    log "<b>waiting for #{@pids.inspect}</b>" if @pids.length > 0
    while @pids.length > 0
      log "Run: waiting for #{@pids.inspect}" if @verbose > 0
      @mutex.synchronize do 
        @pids.each_with_index do |pid, idx|
          begin
            Process.wait(pid[:pid], Process::WNOHANG)
          rescue Errno::ECHILD
            log "deleting #{pid.inspect}" if @verbose > 0
            @pids.delete_at idx
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

  def start_server fullname, scope, locflavor
    scopename = scope['details']
    flavor = scope['flavor']
    scope_id = scope['id']
    log "creating #{fullname}..."
    crestart = Time.now
    out = nil
    curthread = {started_at:Time.now, fullname: fullname, inst: scopename, loc: locflavor}
    curthread[:thread] = Thread.new {
      begin
        curthread[:thread] = Thread.current
        log "#{fullname}: waiting #{@jobwait*1}" if @jobwait > 0
        sleep @jobwait * 1
        @jobwait += 1
        out = create_server(fullname, flavor, locflavor, provisioning_tags(scope))
        if out.nil?
          log "#{fullname} didn't start"
          @errorinsts.push "#(fullname} didn't start"
          delthread curthread        
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
          return false
        end
        log "#{fullname}: password=#{pass.inspect}, createip: #{create_ip.inspect}, diskuuid: #{diskuuid.inspect}" if @verbose > 0
        found = false
        id = ip = nil
        actives = get_active locflavor, false do |mid, mname, mip, mstate|      
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
          return false
        end
        log "Running created #{fullname} ip=#{ip} id=#{id}"
        ssh_remove_ip ip
        delthread curthread
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
    status = ""
    if @threads.length > 0
      status += "   spinning up: "
      @threads.each do |t|
        status += "#{t[:fullname]} "
      end
      status += "\n"
    end
    if @pids.length > 0
      status += "  running   "
      @pids.each do |p|
        status += "#{p[:fullname]} "
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
          if @verbose > 1
            log "Spindriver WD: pids=#{@pids.inspect}"
            log "    threads=#{@threads.inspect}" 
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
                  log "WATCHDOG-#{Process.pid}: killing #{pid[:fullname]}/#{pid[:pid]} because #{((now-pid[:started_at])/60).round} minutes have elapsed"
                  @errorinsts.push "#{pid[:fullname]} (timed out)"
                  @pids.delete_at idx
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
      rescue Exception => e
        log "thread error: #{e.message}"
        end
    end
    @threads = []
    @pids.each do |pid|
      begin
        Process.kill "HUP", pid[:pid]
        log "#{@curprovider}/#{@curlocation} killing pid #{pid[:pid]}" if @verbose > 0
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
#      r.run opts
    end
    system "reset -I 2>/dev/null"
  end

  # driver wrappers

  def create_server name, flavor, location, provtags
    @driver.create_server name, flavor, location, provtags
  end
 

  def delete_server name, id, location, diskuuid=nil
    @driver.delete_server name, id, location, diskuuid
  end

  def get_active location, all, &block
    @driver.get_active location, all, &block
  end

  def fullinstname scope, locflavor
    if @driver.respond_to? :fullinstname
      @driver.fullinstname scope, locflavor
    else
      scopename = scope['details'] || 'compute-'+scope['id']
#      rv = scopename+'-'+(locflavor || 'no-location')
      rv = scopename
      rv.gsub(/[ \/]/, '-')
    end
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
    puts msg if @verbose  > 0
  end

  def logfile
    "logs/#{@driver::CHEF_PROVIDER}.log"
  end

end

