# The Burstorm Perfrun Server Benchmark Suite

## Requirements

1. A test control host running a Linux disto (we use Ubuntu, but it's all good)
2. About 4GB of ram is optimal, but 2GB should work fine for lighter test loads
3. A set of servers that you want to test, and have SSH access to

## Configure the Control Host

To get started, you must have Ruby and friends installed ahead of time.

For Ubuntu-16.04 (and probably previous stable Ubuntu versions too), you should have the following installed:

$ sudo apt-get install sudo apt-get install ssh, git, ruby, ruby-bundler, ruby-dev, build-essential, zlib1g-dev

For Fedora, Centos and other Linux distos, the packages are similar but not necessarily the same... send us the corresponding install line for your favorite disto, and we'll update the doc :)

Once installed, it's time to clone the perfrun repo onto your control host:

$ git clone https://github.com/burstorm/perfrun.git perfrun

$ cd perfrun/perfrun 

$ bundle install


## Create the Perfrun Configuration

The Burstorm App has the ability to generate the necessary configuration to describe the servers you'd like to benchmark and send the results of the benchmark back to the Burstorm app.

To create the configuration, start by logging into your Burstorm app account (https://app.burstorm.com) to set up a Build Spec for the servers to benchmark. Creating a Build in the Burstorm app allows you to create a perfrun configuration file which tells the perfrun software about your servers, keys, etc. So much easier than editing a json config blob by hand.

1. Start by creating a Build Spec, and then a Build to model your infrastructure under test. You can then drag a Linux objective onto the Build to describe the server that you will be testing. In this example, our server is a 1 core, 1 GB ram, 5 GB storage Linux instance.  ![Alt text](/doc/images/perfrun.5.png?raw=true "Build with one objective")

2. Now tell the Burstorm app about the particulars of the server you want to test. With the objective
you created in step (1), click the advanced button, which exposes the Run Spec field. Click on the
Run Spec field and the Run Spec editor will appear: ![Alt text](/doc/images/perfrun.1.png?raw=true "click on run spec") 

3. Enter the dns name (fqdn) or IP address of the server, and the location of the SSH key file that will be used to log in to the server from the Control Host. 
4. Remember the name of your Build Spec you created in this section for later
   
   **NOTE**: Burstorm does NOT upload your server keys EVER. This is just a path to the server keys that will be
used later on your Control Host. ![Alt text](/doc/images/perfrun.2.png?raw=true "edit run spec")

5. Once you've entered your Run Spec information, apply the change, and save the server in the app: ![Alt text](/doc/images/perfrun.3.png?raw=true "save objective")

6. The last step is to generate a Burstorm API key and secret. This allows you to save perfruns to the Burstorm servers under your login name, and keeps them private. ![Alt text](/doc/images/perfrun.6.png?raw=true "create API keys")

Ok, now you've done all of the configuration work you need to do with the Burstorm App. You have 3 more steps to go.

1. take the API key and API secret and place them in a file called config/credentials.config. There is a credentials.config.example file in this directory to show the credential file format.
2. copy your server's SSH key (to allow perfrun to login to your servers) into the perfrun/perfrun/config directory. This MUST be the private key (eg id_rsa, not id_rsa.pub). As we said, we don't upload these, it's just so that perfrun can log into your servers to run performance tests. The default name that perfrun expects is "server.pem". 

## Run the Benchmarks

You're now ready to start the performance test run:

1. $ ./perfrun --verbose --build 'your-build-name'
2. in another window, you can view the log by running  $ tail -f logs/host.log

This will take a while... approximately 15 minutes or so. Get cup of coffee.

**Note:** you can run many different tests from the same control host using different configuration files. You can change the configuration file using the --config switch to perfrun.

### Using an HTTP Proxy

Perfrun requires that the servers under test be able to upload test results to the Burstorm servers.
If your servers under test are walled off from outgoing HTTP requests and require using a HTTP proxy to access other servers on the Internet, you can specify the URL of the proxy using the --proxy option to perfrun. For example:

$ ./perfrun --verbose --proxy http://localhost:8080 --build 'your-build-name'

will instruct perfrun to use the proxy located on your local host listening on port 8080.

## Viewing the Results

Once it completes, you can go back into the Burstorm App to view the results. In this case, we're looking at a Burstorm perfrun of some of our developer machines:

 ![Alt text](/doc/images/perfrun.7.png?raw=true "view results")
 
Within the Burstorm application, you'll be able to view the data sets from your private perfruns, the standard Burstorm perfruns (which include our continual test results of AWS, Google Cloud, Rackspace etc), and any other perfruns you have access to. Once you select the datasets you can than filter them by provider, cores, and lots of other ways.

## Setting up Perfrun for Cloud Providers

[ THIS IS STILL ALL VERY TENTATIVE. /mat]

 Burstorm already does perfruns on a weekly basis for many cloud providers, but if you'd like to spin up, benchmark and reap cloud instances for the drivers we support (aws, rackspace, linode, azure, softlayer, google and digital ocean), you can do that as well. First off, you must provide your credentials to access the cloud providers you want to benchmark. The file config/knife.examples.rb shows the place to put the information credentials that perfrun uses. Perfrun no longer has dependencies on Chef/Knife but the knife.rb key configuration file is still being used. You can google for you provider to find out how to obtain your provider's API credentails (if you don't have them already), and what their format within knife.rb should be. 
 
 Once you've set up knife.rb, you need to create a Build to model the cloud instances you'd like to benchmark. Instead of supplying the host's name in the Run Spec, choose "Run Spec is for a Cloud Provider". Now choose the provider and an instance you'd like to benchmark. Leave the OS image name alone (XXX, still needs to be rationalized /mat). Edit the server SSH key if applicable for the cloud provider (some providers return passwords, which perfrun captures), and the default login name (typically ubuntu for Ubuntu disto images). Click "apply", save the objective, save-as a "perfrun script" and copy the perfrun.config to your server with the perfrun repo as you did above. Run perfrun as usual, and it should fire up yours instances, run the benchmark, and reap them! Let us know if you get this to work... it's still pretty green.

## What Burstorm Uploads in a Perfrun

The Burstorm perfrun server uses a slightly modified version of the venerable UnixBench. The modifications are mainly to add a JSON formatted output (in addition to UnixBench's HTML and plain text output), and to upload the JSON blob to the Burstorm servers. In the JSON blob the app takes a single new field, an objective id, which tells the Burstorm app which Build the perfrun being uploaded is associated with.

### An Example JSON blob:
<pre>
{
 "title":"Benchmark of io1-15-dfw / Ubuntu 14.04.2 LTS on Fri Feb 26 2016",
 "test_date":"Fri 26 Feb 2016 04:21:28 AM UTC",
 "version": "BYTE UNIX Benchmarks (Version 5.1.3)",

 "sysinfo": {
   "host": "io1-15-dfw", 
   "system": "Ubuntu 14.04.2 LTS", 
   "os":"GNU/Linux",
   "os_rel":"3.13.0-55-generic",
   "os_ver":"#92-Ubuntu SMP Sun Jun 14 18:32:20 UTC 2015",
   "ram":"15.3969",
   "storage":"40",
   "storage_type":"HDD",
   "machine":"x86_64/x86_64", 
   "cpu_model":"Intel(R) Xeon(R) CPU E5-2670 0 @ 2.60GHz", 
   "cpu_freq":"2.60GHz", 
   "cores":4
 },
 "cpus": [
   {
    "cpu0": "Intel(R) Xeon(R) CPU E5-2670 0 @ 2.60GHz",
    "bogomips":5200.1, 
    "flags":"x86-64, MMX, Physical Address Ext, SYSENTER/SYSEXIT, SYSCALL/SYSRET"
   },
   {
    "cpu1": "Intel(R) Xeon(R) CPU E5-2670 0 @ 2.60GHz",
    "bogomips":5268.4, 
    "flags":"x86-64, MMX, Physical Address Ext, SYSENTER/SYSEXIT, SYSCALL/SYSRET"
   },
   {
    "cpu2": "Intel(R) Xeon(R) CPU E5-2670 0 @ 2.60GHz",
    "bogomips":5268.8, 
    "flags":"x86-64, MMX, Physical Address Ext, SYSENTER/SYSEXIT, SYSCALL/SYSRET"
   },
   {
    "cpu3": "Intel(R) Xeon(R) CPU E5-2670 0 @ 2.60GHz",
    "bogomips":5269.0, 
    "flags":"x86-64, MMX, Physical Address Ext, SYSENTER/SYSEXIT, SYSCALL/SYSRET"
   }
 ],
 "provider":"", 
 "location":"", 
 "objective":"114335", 
 "mrc":"", 
 "nrc":"", 
 "instance_type":"io1-15", 
 "instance_create_time":"69.866410942", 
 "uptime":"0 min, ",
 "loadav":"0.03,0.01",
 "runlevel":"2", 
 "tests": [
   {
     "cpus": "4", "parallel_processes": "1",
     "start_time": "1456460488", "end_time": "1456460893",
     "run": {
       "system": [
         {
          "baseline":"116700",
          "index":"2487.54629034206",
          "test":"dhry2reg",
          "score":"29029665.2082919",
          "unit":"lps",
          "time":"10.002458",
          "iters":"1"
        },
         {
          "baseline":"55.0",
          "index":"584.313636363637",
          "test":"whetstone-double",
          "score":"3213.725",
          "unit":"MWIPS",
          "time":"9.914",
          "iters":"1"
        },
         {
          "baseline":"43.0",
          "index":"691.893353680763",
          "test":"execl",
          "score":"2975.14142082728",
          "unit":"lps",
          "time":"29.746149",
          "iters":"1"
        },
         {
          "baseline":"3960",
          "index":"2297.41919191919",
          "test":"fstime",
          "score":"909778",
          "unit":"KBps",
          "time":"30",
          "iters":"1"
        },
         {
          "baseline":"1655",
          "index":"1435.63141993958",
          "test":"fsbuffer",
          "score":"237597",
          "unit":"KBps",
          "time":"30",
          "iters":"1"
        },
         {
          "baseline":"5800",
          "index":"4464.21206896552",
          "test":"fsdisk",
          "score":"2589243",
          "unit":"KBps",
          "time":"30",
          "iters":"1"
        },
         {
          "baseline":"12440",
          "index":"1353.2908368001",
          "test":"pipe",
          "score":"1683493.80097933",
          "unit":"lps",
          "time":"10.002951",
          "iters":"1"
        },
         {
          "baseline":"4000",
          "index":"660.321308427098",
          "test":"context1",
          "score":"264128.523370839",
          "unit":"lps",
          "time":"10.00285",
          "iters":"1"
        },
         {
          "baseline":"126",
          "index":"630.941107713273",
          "test":"spawn",
          "score":"7949.85795718724",
          "unit":"lps",
          "time":"30.002926",
          "iters":"1"
        },
         {
          "baseline":"42.4",
          "index":"2073.39674490578",
          "test":"shell1",
          "score":"8791.2021984005",
          "unit":"lpm",
          "time":"60.005445",
          "iters":"1"
        },
         {
          "baseline":"6",
          "index":"4316.68148321909",
          "test":"shell8",
          "score":"2590.00888993145",
          "unit":"lpm",
          "time":"60.02296",
          "iters":"1"
        },
         {
          "baseline":"15000",
          "index":"2095.38793036804",
          "test":"syscall",
          "score":"3143081.89555206",
          "unit":"lps",
          "time":"10.003376",
          "iters":"1"
        }
       ]
     },
     "system_index_score":"1523.67745537904"
   },
   {
     "cpus": "4", "parallel_processes": "4",
     "start_time": "1456460893", "end_time": "1456461297",
     "run": {
       "system": [
         {
          "baseline":"116700",
          "index":"9890.72637120789",
          "test":"dhry2reg",
          "score":"115424776.751996",
          "unit":"lps",
          "time":"10.00442875",
          "iters":"1"
        },
         {
          "baseline":"55.0",
          "index":"2321.71836363637",
          "test":"whetstone-double",
          "score":"12769.451",
          "unit":"MWIPS",
          "time":"9.9485",
          "iters":"1"
        },
         {
          "baseline":"43.0",
          "index":"2449.82360259788",
          "test":"execl",
          "score":"10534.2414911709",
          "unit":"lps",
          "time":"29.17125075",
          "iters":"1"
        },
         {
          "baseline":"3960",
          "index":"1537.29797979798",
          "test":"fstime",
          "score":"608770",
          "unit":"KBps",
          "time":"30",
          "iters":"1"
        },
         {
          "baseline":"1655",
          "index":"1105.19033232628",
          "test":"fsbuffer",
          "score":"182909",
          "unit":"KBps",
          "time":"30",
          "iters":"1"
        },
         {
          "baseline":"5800",
          "index":"3037.20517241379",
          "test":"fsdisk",
          "score":"1761579",
          "unit":"KBps",
          "time":"30",
          "iters":"1"
        },
         {
          "baseline":"12440",
          "index":"5429.70891799424",
          "test":"pipe",
          "score":"6754557.89398484",
          "unit":"lps",
          "time":"10.00501825",
          "iters":"1"
        },
         {
          "baseline":"4000",
          "index":"2289.79464813172",
          "test":"context1",
          "score":"915917.859252688",
          "unit":"lps",
          "time":"10.00376825",
          "iters":"1"
        },
         {
          "baseline":"126",
          "index":"1944.6484918917",
          "test":"spawn",
          "score":"24502.5709978354",
          "unit":"lps",
          "time":"30.006443",
          "iters":"1"
        },
         {
          "baseline":"42.4",
          "index":"4771.30975566537",
          "test":"shell1",
          "score":"20230.3533640212",
          "unit":"lpm",
          "time":"60.0078495",
          "iters":"1"
        },
         {
          "baseline":"6",
          "index":"5476.19415914678",
          "test":"shell8",
          "score":"3285.71649548807",
          "unit":"lpm",
          "time":"60.04169875",
          "iters":"1"
        },
         {
          "baseline":"15000",
          "index":"2725.97244655191",
          "test":"syscall",
          "score":"4088958.66982787",
          "unit":"lps",
          "time":"10.00496075",
          "iters":"1"
        }
       ]
     },
     "system_index_score":"2984.74907160723"
   }
 ]
}
</pre>


