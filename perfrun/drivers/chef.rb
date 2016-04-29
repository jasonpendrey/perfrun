
class ChefDriver < Provisioning

  def self.bootstrap ip, name, provtags, flavor, loc, config='.chef/knife.rb'
    roles = []
    provtags.each do |tag|
      roles.push 'role['+tag+']'
    end
    roles = roles.join ','
    ident = "-i '#{flavor['keyfile']}'"
    system "ssh-keygen -f ~/.ssh/known_hosts -R #{ip} > /dev/null 2>&1"
    scriptln = "bundle exec knife bootstrap -r '#{roles}' -N '#{name}' -V --ssh-user '#{flavor['login_as']}' -c #{config} #{ident} #{flavor['additional']} -y --sudo #{ip} 2>&1"
    puts "#{scriptln}" if @verbose > 0
    rv = ''
    IO.popen scriptln do |fd|
      fd.each do |line|
        puts line if @verbose > 0
        STDOUT.flush
        rv += line
      end
    end
    rv
  end

  def self.delete_node name
    cmd = "bundle exec knife node delete '#{name}' -y"
    `#{cmd}`    
  end

end
