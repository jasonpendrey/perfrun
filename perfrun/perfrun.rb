require 'optparse'
require_relative 'objdriver'

class PerfRun
  TESTTIME = 12*60*60
  CONFIG = "config/perfrun.json"
  CRED_CONFIG = "config/credentials.config"

  def self.oneoffrun     
    @objs.each do |obj|
      next if obj['compute_scopes'].length == 0
      if ARGV.length > 0
        prov = obj['provider']['cloud_driver'] || obj['provider']['name']
        loc = obj['provider']['location_flavor'] || obj['provider']['address']
        next if ARGV[0] != prov
        if ARGV.length > 1
          next if ARGV[1] != loc 
        end
      end
      runone obj
    end
    waitthreads
  end
  
  def self.daemonrun 
    killdaemon true
    nextfill = Time.now
    nobjs = []
    @objs.each do |obj|
      if ARGV.length > 0
        prov = obj['provider']['cloud_driver'] || obj['provider']['name']
        next if ARGV[0] != prov
        if ARGV.length > 1
          loc = obj['provider']['location_flavor'] || obj['provider']['address']
          next if ARGV[1] != loc 
        end
      end
      nobjs.push obj
    end
    @objs = nobjs
    begin
      while true
        puts "\033[1mchecking run at #{Time.now.to_s} (nextfill @#{nextfill.to_s})\033[m"
        checkthreads
        if nextfill <= Time.now
          puts "refilling schedule..."
          @objs.each do |obj|
            obj[:nextrun] = roll
          end
          nextfill = Time.now+(@period*24*60*60)
        end
        @objs.each do |obj|
          obj[:nextrun].sort! { |a, b| 
            a[:run_at] - b[:run_at]
          }
        end      
        @objs.sort! { |a, b| 
          a = a[:nextrun].length > 0 ? a[:nextrun][0][:run_at].to_i : Float::INFINITY
          b = b[:nextrun].length > 0 ? b[:nextrun][0][:run_at].to_i : Float::INFINITY
          a - b
        }
        watchdog
        now = Time.now
        @objs.each do |obj|
          obj[:nextrun].each_with_index do |runtime, idx|
            prov = obj['provider']['name']
            loc = obj['provider']['location_flavor']
            if runtime[:run_at] > now
              puts "#{prov}/#{loc} will run at #{runtime[:run_at]} (#{((runtime[:run_at]-now)/3600).round} hours from now)" if idx == 0
              next
            end
            obj[:nextrun].delete_at idx          
            runone obj
          end
        end
        puts "---------------------"
        STDOUT.flush
        sleep @sleeptmo
      end
    rescue Exception => e
      puts "\n\n***Perfrun: cleaning up because of #{e.inspect} ***"
      @threads.each do |t|
        t[:pd].abort if t[:pd] 
      end
      @threads.each do |t|
        t[:pd].cleanup if t[:pd] 
      end
    ensure
      begin
        File.delete("#{Dir.pwd}/logs/#{@programname}.pid")
      rescue
      end
    end
  end

  def self.runone obj
    prov = obj['provider']['name']
    loc = obj['provider']['location_flavor']
    opts = {}
    opts[:verbose] = @verbose
    opts[:object] = obj
    opts[:tags] = @tags
    opts[:mode] = @mode
    opts[:autodelete] = true
    opts[:test_connection] = true
    opts[:app_host] = @app_host if @app_host
    if @mode == 'run' or @mode == 'delete'
      curthread = {started_at:Time.now, prov: prov, loc: loc}
      curthread[:thread] = Thread.new {    
        curthread[:thread] = Thread.current
        puts "#{@mode.capitalize} from #{prov}/#{loc} at #{Time.now}"
        curthread[:pd] = pd = ObjDriver.new
        pd.verbose = @verbose
        pd.run opts do |server|
          if @mode == 'run' and server[:action] == 'running'
            pd.perfrun server[:scope], server[:flavor], server[:ip], server[:runtime] 
          end
        end
        delthread curthread
      }
      @mutex.synchronize do 
        @threads.push curthread unless curthread[:dead]
      end
    else
      puts "#{@mode.capitalize} #{prov}/#{loc}"
      pd = ObjDriver.new
      pd.verbose = @verbose
      pd.run opts
    end
  end

  def self.main
    @programname = $PROGRAM_NAME
    @debug = false
    @mode = 'run'
    @verbose = 0
    @daemon = false
    @dryrun = false
    @threads = []
    @config = nil
    @period = 7         # period length in days
    @nperperiod = 1     # number of times to run in the period
    @hoursperday = 24   # number of hours to use per day
    @sleeptmo = 60*30   # wake timeout to check on progress    
    @mutex = Mutex.new
    $LOAD_PATH.push "#{Dir.pwd}/config"
    begin
      load CRED_CONFIG
    rescue
    end
    if ARGV.length > 0
      OptionParser.new do |o|
        o.on('--app_host HOST') { |b|
          @app_host = b
        }
        o.on('--delete') { |b|
          @mode = 'delete'
        }
        o.on('--list') { |b|
          @mode = 'list'
        }
        o.on('--verbose', '-v') { |b|
          @verbose = 1
        }
        o.on('--daemon', '-d') { |b|
          @daemon = true
        }
        o.on('--dryrun') { |b|
          @dryrun = true
        }
        o.on('--config CONFIG') { |b|
          @config = b
        }
        o.on('--build id','-b id') { |b|                    
          @build_name = b
        }
        o.on('--fulllist') { |b|
          @mode = 'fulllist'
        }
        o.on('--kill') { |b|
          killdaemon false
          exit
        }
        o.on('--debug') { |b|
          @debug = true
        }
        o.on('--nperperiod N') { |b|
          @nperperiod = Integer b
        }
        o.on('--period N') { |b|
          @period = Integer b
        }
      end.parse!
    end

    start = Time.now
    if @debug
      @period = 1
      @nperperiod = 1
      @hoursperday = 24
      @sleeptmo = 60*5
    end  

    if @config
      begin
        if File.exist? @config
          @project = JSON.parse File.read(@config)
        elsif File.exist? 'config/'+@config
          @project = JSON.parse File.read('config/'+@config)
        else
          raise 'no such file: '+@config
        end
      rescue Exception => e
        puts "JSON parse error: #{e.message}"
        exit 1
      end
    else
      h = APP_HOST
      if @build_name.nil?
        now = Time.now
        @build_name = "Perfrun #{now.month}/#{now.year}"
      end
      begin
        id = Integer @build_name
      rescue
        cmd = "curl -X GET -k --user '#{APP_KEY}:#{APP_SECRET}' -H \"Content-Type: application/json\" https://#{h}/api/projects.json?for_select=true 2>/dev/null"
        jproj = `#{cmd}`
        if jproj.blank?
          puts "no build list returned. probably bad credentials: try executing the following to debug..."
          puts "#{cmd}"
          exit 1
        else
          begin
            projs = JSON.parse jproj
          rescue Exception => e
            raise "bad json: #{e.message} '#{jproj}"
          end
        end
        id = nil
        projs.each do |proj|
          if proj['name'] == @build_name and proj['ptype'] != 'objective'
            id = proj['id']
            break
          end
        end
      end
      raise "can't find #{@build_name}" if id.nil?
      @buildid = id
      cmd = "curl -X GET -k --user '#{APP_KEY}:#{APP_SECRET}' -H \"Content-Type: application/json\" https://#{h}/api/builds/#{id}.json 2>/dev/null"
      begin
        out = `#{cmd}`            
        if out.blank?
          puts "build not found for: #{id}. command that failed: "
          puts cmd
          exit 1
        else
          @project = JSON.parse out
        end
      rescue Exception => e
        puts "JSON parse error: #{e.message}"
        exit 1
      end
      if @project['ajax_error']
        puts "#{@build_name} #{id}: #{@project['ajax_error']}"
        exit 1
      end
      @config = "build #{@build_name}"
    end
    nstart = 0
    case @project['ptype']
    when 'contract'
      @objs = @project['contracts']
    when 'quote'
      @objs = @project['quotes']
    when 'objective'
      @objs = @project['objectives']
    else
      if @project['compute_scopes']
        @objs = [@project]
      else
        puts "Unknown project type: #{@project['ptype']}. Probably the wrong kind of JSON API file."
        puts @project.inspect
        exit 1
      end
    end
    # XXX for host driver
    $objs = @objs
    @tags = @project['project_tags']
    if @daemon
      daemonrun
    else
      oneoffrun
    end
    puts "\033[1mPerfrun finished after #{((Time.now-start)/60).round(1)} minutes\033[m"
    exit 0
  end

  private

  def self.roll
    rv = []
    n = @nperperiod
    while n > 0
      day = rand 0..@period-1
      hour = rand(0..@hoursperday-1)
      time = Time.new
      time += 24*60*60*day
      time += 60*60*hour
      found = false
      rv.each do |r|
        if time.to_i < r[:run_at].to_i+TESTTIME and time.to_i >= r[:run_at].to_i-TESTTIME
          found = true
          break
        end
      end
      next if found
      rv.push({run_at: time, day: day, hour: hour})
      n-= 1
    end
    rv
  end

  def self.killdaemon recordnew
    begin
      fname = "#{Dir.pwd}/logs/#{@programname}.pid"
      oldpid = nil
      if File.exists? (fname)
        pidfile = File.open(fname, 'r')  
        oldpid = pidfile.read
        pidfile.close
      end
      if recordnew
        pidfile = File.open(fname, 'w')  
        pidfile.write Process.pid.to_s
        pidfile.close
      end
      begin
        unless oldpid.nil?
          puts "perfrun killing #{oldpid}" 
          Process.kill("HUP", oldpid.to_i)
        end
      rescue
        puts "can't kill #{oldpid}"
      end
    rescue Exception => e
      puts "something went wrong with cleaning up old daemons: #{e.message}"
    end    
  end

  def self.waitthreads
    puts "\033[1mStart waiting for #{@threads.length} threads: #{threadlist}\033[m" if @threads.length > 0 and @verbose > 0
    begin
      while @threads.length > 0
        @mutex.synchronize do 
          puts "-----------" if @verbose > 0
          now = Time.now
          @threads.each_with_index do |t, idx|
            if ! t[:thread].status or t[:dead]
              @threads.delete_at idx
              next
            end
            if @verbose > 0
              puts "waiting #{(now-t[:started_at]).round}s for #{t[:prov]}/#{t[:loc]} to finish (running #{((Time.now-t[:started_at])/60).to_i} minutes)" 
              puts t[:pd].status if t[:pd]
            end
          end
        end
        STDOUT.flush
        sleep 10
      end      
    rescue Exception => e
      puts "\n\n***Perfrun: cleaning up because of #{e.inspect} ***"
      puts "#{e.backtrace.join "\n"}" if @verbose > 0 and e.class != Interrupt
      @threads.each do |t|
        t[:pd].abort if t[:pd] 
      end
      @threads.each do |t|
        t[:pd].cleanup if t[:pd] 
      end
    end
  end
  
  def self.checkthreads
    @mutex.synchronize do 
      @threads.each_with_index do |t, idx|
        if ! t[:thread].status or t[:dead]
          @threads.delete_at idx
          next
        end
        puts "waiting for #{t[:prov]}/#{t[:loc]} to finish (running #{((Time.now-t[:started_at])/60).to_i} minutes)" if @verbose > 0
      end
    end
    STDOUT.flush
  end

  def self.delthread thread
    @mutex.synchronize do 
      thread[:dead] = true
      @threads.each_with_index do |t, idx|
        next if t != thread
        @threads.delete_at idx
        break
      end
    end
  end

  def self.watchdog
    return if @watchdog
    @watchdog = Thread.new {
      while true        
        begin
          # kill off instances that were left orphaned
          if @threads.length == 0
            now = Time.now
            found = false
            # but don't kill them if it's about to run
            @objs.each do |obj|
              next if obj[:nextrun].length == 0
              if obj[:nextrun][0][:run_at] < now+5*60
                found = true
                break
              end
            end
            next if found
            puts "\033[1mrunning kill van...\033[m"
            dbg = @debug ? "--debug" : ''
            ver = @verbose ? "--verbose" : ''
            cfg = @buildid ? "-b #{@buildid}" : "-c #{@config}"
            apph = @app_host ? "--app-host #{@app_host}" : ""
            out = `bundle exec ./perfrun #{dbg} #{ver} #{cfg} #{apph} --delete`
            puts out if @verbose > 0
            puts "\033[1mkill van done.\033[m"
          end
        rescue Exception => e
          puts "WATCHDOG Exception: #{e.message}"
          puts "#{e.backtrace.join "\n"}"
        end
        sleep 10*60
      end
    }
  end

  def self.threadlist
    rv = ''
    @threads.each do |t|
      rv += " (#{t[:prov]}/#{t[:loc]})"
    end
    rv 
  end


end

