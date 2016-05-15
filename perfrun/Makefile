IDENT := -i ~/.ssh/deployer
USER := deployer
ARCH := $(shell uname -m)
OS := $(shell uname)
LOC := /srv/bench-disto/

publish: 
	cd ../BurUnixBench; mkdir -p tmp
	cd ../BurUnixBench; cp -f RunRemote $(LOC); make noarch-tar; cp -f tmp/BurUnixBench-noarch.tgz $(LOC)
	cd ../BurUnixBench; make tar; cp -f tmp/BurUnixBench-$(ARCH)-$(OS).tgz $(LOC)
test-publish: 
	cd ../BurUnixBench; for host in "test" "ops" ; do echo "copying to $$host"; scp $(IDENT) $(LOC)* $(USER)@$$host.burstorm.com:$(LOC); done

prod-publish: 
	cd ../BurUnixBench; for host in "pgs" "rmq" "web03" ; do echo "copying to $$host"; scp $(IDENT) $(LOC)* $(USER)@$$host.burstorm.com:$(LOC); done
