
class ChefDriver < Provisioning

  def self.bootstrap ip, name, provtags, flavor, loc, pass, config='.chef/knife.rb'
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
    while nretry > 0
      neterr = false
      rv = ''
      IO.popen scriptln do |fd|
        fd.each do |line|
          puts line if @verbose > 0
          neterr = line.start_with? "ERROR: Network Error:" if ! neterr
          STDOUT.flush
          rv += line
        end
      end
      return rv if ! rv.blank? and ! neterr
      nretry -= 1
      if nretry > 0
        puts "CHEF: bootstrap error (will retry): #{rv}"
        sleep 10
      else
        puts "CHEF: giving up bootstrap: #{rv}"
      end
    end
    rv
  end

  def self.delete_node name
    cmd = "bundle exec knife node delete '#{name}' -y"
    `#{cmd}`    
  end

end
