require 'active_record'

class DbLog

  @withdb = false

  def self.initdb 
    @withdb = true
    apploc = '../../dev'
    dbconfig = YAML::load(File.open("#{apploc}/.chef/database.yml"))
    ActiveRecord::Base.establish_connection(dbconfig[ENV['RAILS_ENV'] || 'production'])
    require "#{apploc}/app/models/perf_log.rb"
    require "#{apploc}/app/models/provider.rb"
  end

  def self.inst_status status, message, instance, started_at
    return unless @withdb
    ActiveRecord::Base.connection_pool.with_connection do
      p = PerfLog.new
      p.status = status
      p.message = message
      p.instance = instance
      p.started_at = started_at
      p.save!
    end
  end

  def self.run_started
    return unless @withdb
    @started_at = Time.now
  end

  def self.run_status provider, status, message
    return unless @withdb
    ActiveRecord::Base.connection_pool.with_connection do
      p = PerfLog.new
      p.provider_id = provider.id
      p.status = status
      p.message = message
      p.started_at = @started_at
      p.save!
    end
  end

end
