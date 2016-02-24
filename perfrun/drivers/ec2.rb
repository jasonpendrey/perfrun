class Ec2Driver
  PROVIDER='Amazon/AWS'
  CHEF_PROVIDER='ec2'
  MAXJOBS = 1
  PROVIDER_ID = 67
  LOGIN_AS='ubuntu'

  def self.get_active location, all, &block
    servers = `bundle exec knife #{CHEF_PROVIDER} server list --region #{location}`
    srv = servers.split "\n"
    srv.shift
    srv.each do |s|
      line = s.split ' '
      id = line[0]
      name = line[1]
      ip = line[2]
      state = line.last
      if state == 'running' or all
        yield id, name, ip, state
      end
    end
  end	     

  def self.create_server name, instance, location, login_as, ident
    roles = ""
    case location
      when 'us-east-1'
      image = 'ami-9a562df2'
      when 'us-west-1'
      image = 'ami-057f9d41'
      when 'us-west-2'
      image = 'ami-51526761'
      when 'eu-west-1'
      image = 'ami-2396f654'
      when 'eu-central-1'
      image = 'ami-00dae61d'
      when 'ap-southeast-1'
      image = 'ami-76546924'
      when 'ap-southeast-2'
      image = 'ami-cd611cf7'
      when 'ap-northeast-1'
      image = 'ami-c011d4c0'
      when 'sa-east-1'
      image = 'ami-75b23768'
    end
    ident = "-i #{ident} -x ubuntu -S benchmark"
    return `yes|bundle exec knife #{CHEF_PROVIDER} server create --region "#{location}" -N #{name} --flavor #{instance} --image #{image} #{ident} --run-list "#{roles}"`

  end

  def self.delete_server s, id, location, diskuuid=nil
    "yes|bundle exec knife #{CHEF_PROVIDER} server delete --region #{location} -N #{s} #{id} --purge"
  end
end
