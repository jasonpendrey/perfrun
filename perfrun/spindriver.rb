require 'optparse'
require 'active_support/all'  # for camelize

class SpinDriver
  WATCHDOGTMO = 30*60       # for creation
  SSHOPTS = "-o LogLevel=quiet -oStrictHostKeyChecking=no"

  def initialize
    Dir["./drivers/*.rb"].each {|file| require file }
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
    @curprovider = object['provider']['name']
    @curlocation = object['provider']['location_flavor'] || object['provider']['address']
    @driver = ((object['provider']['cloud_driver'] || 'host').camelize+'Driver').constantize
    @verbose = opts[:verbose] || 0
    @driver.verbose = 1
    if @mode == 'run'
      @started_at = Time.now
    end
    @app_host = opts[:app_host] if opts[:app_host]
    @errorinsts = [] if @mode == 'run'
    @threads = []
    @mutex = Mutex.new
    @jobwait = 0 
    watchdog
    begin
      active = {}
      alines = []
      fetchedactive = false
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
        if ! fetchedactive
          get_active @curlocation, @mode != 'run' do |id, name, ip, state|
            active[name] = name
            alines.push({id:id, name:name, ip:ip, state: state})
          end
          active = active.values          
          fetchedactive = true
        end
        aline = nil
        alines.each do |a|
          next if a[:name] != fullname
          aline = a
          break
        end
        if @mode == 'run'
          if ! active.include? fullname or ! aline or ! aline[:ip]
            next unless start_server fullname, scope, @curlocation, block
          else
            log "#{fullname} already exists... skipping"
            next
          end
          if @threads.length >= @maxjobs
            waitthreads
          end
        else
          alines.each do |aline|
            if aline[:name] == fullname
              if @mode == 'delete'
                puts delete_server(fullname, aline[:id], @curlocation, flavor)
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
    rescue Exception => e
      log "\n\n***Spindriver: cleaning up because of #{e.inspect} ***"
      log e.backtrace.join "\n"
      log " threads: #{@threads.inspect}"
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

  def start_server fullname, scope, locflavor, block
    scopename = scope['details']
    flavor = scope['flavor']
    scope_id = scope['id']
    log "creating #{fullname}..."
    crestart = Time.now
    curthread = {started_at:Time.now, fullname: fullname, inst: scopename, loc: locflavor}
    curthread[:thread] = Thread.new {
      begin
        curthread[:thread] = Thread.current
        log "#{fullname}: waiting #{@jobwait*1}" if @jobwait > 0
        sleep @jobwait * 1
        @jobwait += 1
        server = create_server(fullname, scope, flavor, locflavor, provisioning_tags(scope))
        if server.nil?
          log "#{fullname} didn't start"
          @errorinsts.push "#(fullname} didn't start"
        else
          cretime = (Time.now-crestart)
          log "Created #{fullname} ip=#{server[:ip]} id=#{server[:id]} in #{cretime.round} seconds"
          # XXX should I remove the ip from known_hosts here too?? /mat
          ssh_remove_ip server[:ip]
          block.call scope, fullname, server[:id], server[:ip] if block
        end
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
            log "Spindriver WD: threads=#{@threads.inspect}" 
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
    if @mode == 'run'
      opts = @opts.clone
      opts[:mode] = 'delete'
      r = self.class.new
#      r.run opts
    end
    system "reset -I 2>/dev/null"
  end

  # driver wrappers

  def create_server name, scope, flavor, location, provtags
    @driver.create_server name, scope, flavor, location, provtags
  end

  def delete_server name, id, location, flavor
    @driver.delete_server name, id, location, flavor
  end

  def get_active location, all, &block
    @driver.get_active location, all, &block
  end

  def fullinstname scope, locflavor
    if @driver.respond_to? :fullinstname
      @driver.fullinstname scope, locflavor
    else
      scopename = scope['details'] || 'compute-'+scope['id']
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

