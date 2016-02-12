IDENT := -i ~/.ssh/deployer
ARCH := $(shell uname -m)
OS := $(shell uname)

publish: 
	cd ../BurUnixBench; scp RunRemote mike-dev.burstorm.com:/srv/bench-disto/; make noarch-tar; scp tmp/BurUnixBench-noarch.tgz mike-dev.burstorm.com:/srv/bench-disto/
	cd ../BurUnixBench; make tar; scp tmp/BurUnixBench-$(ARCH)-$(OS).tgz mike-dev.burstorm.com:/srv/bench-disto/
test-publish: 
	cd ../BurUnixBench; scp $(IDENT) /srv/bench-disto/* test.burstorm.com:/srv/bench-disto/

prod-publish: 
	cd ../BurUnixBench; scp $(IDENT) /srv/bench-disto/* app01.burstorm.com:/srv/bench-disto/; scp $(IDENT) /srv/bench-disto/* app02.burstorm.com:/srv/bench-disto/
