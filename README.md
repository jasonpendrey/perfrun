# perfrun
This is the Burstorm public cloud server performance benchmarking suite.

To get started, you must first clone this repo onto a Linux server or Desktop machine that you have
login access to. The server should have about 4G of ram, have and have Ruby installed. Once you 
have cloned the repo, change directory to the top level of the repo and:

$ git clone git@github.com:burstorm/perfrun.git perfrun
$ cd perfrun 
$ bundle install

which will install of the ruby dependencies needed by perfrun. 

Next up, we need to configure the perfrun software to:

1. describe the servers you'd like to test
2. get the credentials to write the test results back to the Burstorm server

To create the configuration, start by using the Burstorm app
(https://app.burstorm.com) to set up a blueprint of the servers you want to benchmark. Creating a blueprint
in the Burstorm app allows us to create a perfrun configuration file which tells the perfrun software
about your servers, keys, etc. So much easier than editing a json config blob by hand.

1. Start by creating a blueprint, and a contract to model your infrastructure under test. You can then drag a linux objective onto the contract to describe the server(s) that you will be testing. In this example, our server
is a 1 core, 1 GB ram, 5 GB storage Linux instance.  ![Alt text](/doc/images/perfrun.5.png?raw=true "contract with one objective")

2. We then need to tell the Burstorm app about particulars about the server we want to test. With the objective
we created in step (1), we can click the advanced button, which exposes the run spec field. Click on the
Run Spec field and the Run Spec editor will appear:  
Enter the dns name of the server, and the name of the SSH key file that will be used to log in to the server.  **NOTE**: Burstorm does NOT upload your server keys EVER. This is just a path to the server keys that will be
added later. ![Alt text](/doc/images/perfrun.1.png?raw=true "edit run spec")  ![Alt text](/doc/images/perfrun.2.png?raw=true "edit run spec")

3. Once you've entered your Run Spec information, apply the change, and save the server in the app: ![Alt text](/doc/images/perfrun.3.png?raw=true "save objective")


4. We're now ready to export the perfrun configuration file. Click on the Perfrun Script item in the Save-A pulldown, and the configuration will be downloaded to your computer. ![Alt text](/doc/images/perfrun.4.png?raw=true "save-as perfrun")

5. The last step is to generate a Burstorm API key and secret. This allows you to save perfruns to the Burstorm servers under your login name, and keeps them private. ![Alt text](/doc/images/perfrun.6.png?raw=true "create API keys")

Ok, now we've done all of the configuration work we need to do with the Burstorm App. We have 3 more steps to go.

1. take the config file (perfrun.config) we created above and place it into the perfrun/perfrun/config directory.
2. take the API key and API secret and place them in a file called credentials.config. There is a credentials.config.example file in this directory to show the credential file format.
3. copy the SSH keys to log into your server into the perfrun/perfrun/config directory. this MUST be the private key. as we said, we don't upload these, it's just so that perfrun can log into your servers to run performance tests.

We're now ready to try a perfrun:

1. ./perfrun --verbose
2. in another window, you can view the log by running  $ tail -f logs/host.log

Once it completes, you can go back into the Burstorm App to view the results:

