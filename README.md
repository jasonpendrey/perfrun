# The Burstorm Perfrun Server Benchmark Suite

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
Run Spec field and the Run Spec editor will appear: ![Alt text](/doc/images/perfrun.1.png?raw=true "click on run spec") 

3. Enter the dns name of the server, and the name of the SSH key file that will be used to log in to the server.  **NOTE**: Burstorm does NOT upload your server keys EVER. This is just a path to the server keys that will be
added later. ![Alt text](/doc/images/perfrun.2.png?raw=true "edit run spec")

4. Once you've entered your Run Spec information, apply the change, and save the server in the app: ![Alt text](/doc/images/perfrun.3.png?raw=true "save objective")


5. We're now ready to export the perfrun configuration file. Click on the Perfrun Script item in the Save-A pulldown, and the configuration will be downloaded to your computer. ![Alt text](/doc/images/perfrun.4.png?raw=true "save-as perfrun")

6. The last step is to generate a Burstorm API key and secret. This allows you to save perfruns to the Burstorm servers under your login name, and keeps them private. ![Alt text](/doc/images/perfrun.6.png?raw=true "create API keys")

Ok, now we've done all of the configuration work we need to do with the Burstorm App. We have 3 more steps to go.

1. take the config file (perfrun.config) we created above and place it into the perfrun/perfrun/config directory.
2. take the API key and API secret and place them in a file called credentials.config. There is a credentials.config.example file in this directory to show the credential file format.
3. copy the SSH keys to log into your server into the perfrun/perfrun/config directory. this MUST be the private key. as we said, we don't upload these, it's just so that perfrun can log into your servers to run performance tests.

We're now ready to try a perfrun:

1. ./perfrun --verbose
2. in another window, you can view the log by running  $ tail -f logs/host.log

Once it completes, you can go back into the Burstorm App to view the results. In this case, we're looking at a Burstorm perfrun of some of our developer machines:

 ![Alt text](/doc/images/perfrun.7.png?raw=true "view results")
 
 With the app, you'll be able to view data sets from your perfruns, the standard Burstorm perfruns including AWS, Google Cloud, etc, and any other perfruns you have access to. Filter them by provider, cores, and lots of other ways.

## What we Upload

The Burstorm perfrun server uses a slightly modified version of the venerable UnixBench. The modifications are mainly to add a JSON formater (in addition to UnixBench's HTML and plain text output), and to upload the JSON blob to the Burstorm servers. In the JSON blob the app takes a single new field, an objective id, which tells the Burstorm app which contract the perfrun being uploaded is associated with. That's basically all we've done thus far.

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


