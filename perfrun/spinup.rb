require 'optparse'
require_relative 'objdriver'

class Spinup
  CONFIG = "config/spinup.json"
  CRED_CONFIG = "config/credentials.config"

  def self.oneoffrun   
    @objs.each do |obj|
      next if obj['compute_scopes'].length == 0      
      if ARGV.length > 0
        next if obj['name'].strip != ARGV[0].strip
      end
      found = true
      if ARGV.length > 1
        found = false
        scopes = []
        obj['compute_scopes'].each do |scope|
          if ARGV[1..-1].include? scope['details'].strip
            scopes.push scope 
            found = true
          end
        end
      else
        scopes = nil
      end
      runone obj, scopes if found
    end
    waitthreads
  end
  
  def self.runone obj, scopes=nil
    prov = obj['provider']['name']
    loc = obj['provider']['location_flavor'] || obj['provider']['address']
    opts = {}
    opts[:verbose] = @verbose
    opts[:object] = obj
    opts[:tags] = @tags
    opts[:test_connection] = true
    opts[:mode] = @mode
    opts[:maxjobs] = @maxjobs
    opts[:scopes] = scopes
    opts[:app_host] = @app_host if @app_host
    opts[:proxy] = @proxy if @proxy
    puts "#{@mode.capitalize} #{obj['name']}@#{prov}/#{loc} using #{@config}"
    if @mode == 'run' or @mode == 'delete'
      curthread = {started_at:Time.now, prov: prov, loc: loc}
      curthread[:thread] = Thread.new {    
        curthread[:thread] = Thread.current
        curthread[:pd] = pd = ObjDriver.new
        pd.run opts do |server|
          runaction (server)
        end
        delthread curthread
      }
      @mutex.synchronize do
        @threads.push curthread unless curthread[:dead]
      end
    else
      pd = ObjDriver.new
      pd.verbose = @verbose
      pd.run opts
    end
  end

  def self.runaction server
  end


  def self.main
    @debug = false
    @mode = 'run'
    @verbose = 0
    @dryrun = false
    @threads = []
    @config = CONFIG
    @maxjobs = 4
    
    @mutex = Mutex.new
    $LOAD_PATH.push "#{Dir.pwd}/config"
    begin
      load CRED_CONFIG
    rescue
    end
    @config_string = nil
    if ARGV.length > 0
      OptionParser.new do |o|
        o.on('--proxy URL') { |b|
          @proxy = b
        }
        o.on('--app_host HOST') { |b|
          @app_host = b
        }
        o.on('--delete') { |b|
          @mode = 'delete'
        }
        o.on('--list', '-l') { |b|
          @mode = 'list'
        }
        o.on('--verbose', '-v') { |b|
          @verbose = 2
        }
        o.on('--maxjobs jobs') { |b|
          @maxjobs = Integer(b)
        }
        o.on('--dryrun') { |b|
          @dryrun = true
        }
        o.on('--config CONFIG','-c CONFIG') { |b|
          @config = b
        }
        o.on('--build id','-b id') { |b|
          h = APP_HOST
          begin
            id = Integer b
          rescue
            cmd = "curl -X GET -k --user '#{APP_KEY}:#{APP_SECRET}' -H \"Content-Type: application/json\" https://#{h}/api/projects.json?for_select=true 2>/dev/null"
            jproj = `#{cmd}`
            begin
              projs = JSON.parse jproj
            rescue Exception => e
              raise "bad json: #{e.message}"
            end
            id = nil
            projs.each do |proj|
              if proj['name'] == b and proj['ptype'] != 'objective'
                id = proj['id']
                break
              end
            end
            
          end
          raise "can't find #{b}" if id.nil?
          cmd = "curl -X GET -k --user '#{APP_KEY}:#{APP_SECRET}' -H \"Content-Type: application/json\" https://#{h}/api/builds/#{id}.json 2>/dev/null"
          @config_string = `#{cmd}`
          @config = "build #{b}"
        }
        o.on('--fulllist') { |b|
          @mode = 'fulllist'
        }
        o.on('--debug') { |b|
          @debug = true
        }
        o.on('-h','--help') { |b|
          puts o
          exit 0
        }
      end.parse!
    end

    start = Time.now
    begin      
      if @config_string
        @project = JSON.parse @config_string
      elsif File.exist? @config
        @project = JSON.parse File.read(@config)
      elsif File.exist? 'config/'+@config
        @project = JSON.parse File.read('config/'+@config)
      else
        raise 'no such file: '+@config
      end
    rescue Exception => e
      puts "config load error: #{e.message}"
      exit 1
    end
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
    $objs = @objs
    @tags = @project['project_tags']
    oneoffrun
    puts "<b>Spinup finished after #{((Time.now-start)/60).round(1)} minutes</b>"
    exit 0
  end

  private

  def self.waitthreads
    puts "<b>Start waiting for #{@threads.length} threads: #{@threads.inspect}</b>" if @threads.length > 0 and @verbose > 0
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
      puts "\n\n***Spinup: cleaning up because of #{e.inspect} ***"
      puts "#{e.backtrace.join "\n"}" if @verbose > 0 and e.class != Interrupt
      @threads.each do |t|
        t[:pd].abort if t[:pd] 
      end
      @threads.each do |t|
        t[:pd].cleanup if t[:pd] 
      end
    end
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

end
