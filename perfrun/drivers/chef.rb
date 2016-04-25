

class ChefDriver

  @verbose = 0

  def self.verbose= n
    @verbose = n
  end

  def self.chef_bootstrap ip, name, provtags, flavor, loc, pass, config='.chef/knife.rb'
    roles = []
    provtags.each do |tag|
      roles.push 'role['+tag+']'
    end
    roles = roles.join ','
    ident = ''
    if pass
      ident = "-P '#{pass}'"
    else
      ident = "-i '#{flavor['keyfile']}'"
    end
    system "ssh-keygen -f ~/.ssh/known_hosts -R #{ip} > /dev/null 2>&1"
    scriptln = "bundle exec knife bootstrap -r '#{roles}' -N '#{name}' -V --ssh-user '#{flavor['login_as']}' -c #{config} #{ident} #{flavor['additional']} -y --sudo #{ip} 2>&1"
    puts "#{scriptln}" if @verbose > 0
    nretry = 3
    err = false
    while nretry > 0
      rv = ''
      IO.popen scriptln do |fd|
        fd.each do |line|
          puts line if @verbose > 0
          err = line.start_with? "ERROR: " if ! err
          STDOUT.flush
          rv += line
        end
      end
      return rv if ! err
      nretry -= 1
      if nretry > 0
        puts "CHEF: bootstrap error (will retry): #{rv}"
        sleep 5
      else
        puts "CHEF: giving up bootstrap: #{rv}"
      end
    end
    rv
  end

  def self.chef_delete_node name
    cmd = "bundle exec knife node delete '#{name}' -y"
    `#{cmd}`    
  end

end
