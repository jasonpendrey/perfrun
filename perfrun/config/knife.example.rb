# See https://docs.chef.io/config_rb_knife.html for more information on knife configuration options

current_dir = File.dirname(__FILE__)
log_level                :info
log_location             STDOUT
node_name                "your-node"
client_key               "#{current_dir}/your-opscode-credentials.pem"
chef_server_url          "https://api.opscode.com/organizations/your-organization"
cookbook_path            ["#{current_dir}/../cookbooks"]

# See more Chef/Rackspace documentation at https://github.com/opscode/knife-rackspace
knife[:softlayer_username] = ''
knife[:softlayer_api_key] = ''
knife[:softlayer_default_domain] = ''
knife[:rackspace_api_username] = ""
knife[:rackspace_api_key] = ""
knife[:linode_api_username] = ""
knife[:linode_api_key] = ""
knife[:digital_ocean_access_token] = ''
knife[:aws_ssh_key_id] = ''
knife[:aws_access_key_id] = ''
knife[:aws_secret_access_key] = ''
knife[:azure_publish_settings_file] = "azure.publishsettings"
knife[:compute_credential_file] = "#{current_dir}/.google-compute.json"
knife[:gce_zone] = "us-central1-a"
