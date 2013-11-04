#
# Cookbook Name:: glance
# Recipe:: api
#
#

include_recipe "#{@cookbook_name}::common"

Chef::Log.info(">>>>>> Glance: Api Recipe")

# Retrieves virtual ip addresses from LoadBalancer
admin_vip = node[:haproxy][:admin_ip]
public_vip = node[:haproxy][:public_ip]
db_root_password = node["percona"]["server_root_password"]

############################### RabbitMQ #######################
# Retrieves RabbitMQ attributes values
rabbitmq_cluster = search(:node, "roles:rabbitmq") || []
  if rabbitmq_cluster.length > 0
    rabbitmq = rabbitmq_cluster[0]
    rabbitmq = node if rabbitmq.name == node.name
  else
    rabbitmq = node
  end

# Get RabbitMQ endpoint
node.set["glance"]["rabbitmq"]["host"] = admin_vip

# Get RabbitMQ port
node.set["glance"]["rabbitmq"]["port"] = rabbitmq['rabbitmq']['port']

# Get RabbitMQ user
node.set["glance"]["rabbitmq"]["user"] = rabbitmq['rabbitmq']['user']

# Get RabbitMQ password
node.set["glance"]["rabbitmq"]["password"] = rabbitmq['rabbitmq']['password']

# Get RabbitMQ vhost
node.set["glance"]["rabbitmq"]["vhost"] = rabbitmq['rabbitmq']['vhost']

# Get RabbitMQ Use SSL
node.set["glance"]["rabbitmq"]["ssl"] = rabbitmq['rabbitmq']['ssl']
 
### File storage --> Notifier strategy = rabbit for image sync
if node[:glance][:default_store] == 'file'
   node.set[:glance][:notifier_strategy] = 'rabbit' 
   Chef::Log.info("Default store = File ") 
end   

##################################################################
############################ Image_sync ##########################

### If File storage is selected we must use image sync to syncronize glance images across our HA nodes
# Notifier strategy must be set to 'rabbit' for image sync
if node[:glance][:default_store] == 'file'
   Chef::Log.info("Default store = File ")
   # Notifier strategy must be set to 'rabbit' for image sync 
   node.set[:glance][:notifier_strategy] = 'rabbit'

   # Installs python-lockfile package
   # This package is needed to run glance image sync script 
   package "python-lockfile" do
     action :install
   end

   ### Builds a string containing Glance nodes hostnames separated by a comma
   service_name = node[:glance][:config][:environment]
   # Retrieves glance proposal name 
   proposal_name = service_name.split('-')
   bcproposal = "bc-glance-"+proposal_name[2]
   getrmip_db = data_bag_item('crowbar', bcproposal)
   # Hostname node1 
   glancehost1 = getrmip_db["deployment"]["glance"]["elements"]["glance-server"][0]
   # Hostname node2 
   glancehost2 = getrmip_db["deployment"]["glance"]["elements"]["glance-server"][1]
   # Hostname node2 
   glancehost3 = getrmip_db["deployment"]["glance"]["elements"]["glance-server"][2]
   glancehosts = glancehost1 + "," + glancehost2 + "," + glancehost3

   Chef::Log.info("Glancehosts for image sync file: #{glancehosts}")
   # Copies glance image sync conf file over
   template "/etc/glance/glance-image-sync.conf" do
     source "glance-image-sync.conf.erb"
     owner node[:glance][:user]
     group "root"
     mode 0644
     variables(
       :glancehosts => glancehosts
     )
   end

   # Copies glance image sync python file over
   cookbook_file "/etc/glance/glance-image-sync.py" do
     source "glance-image-sync.py"
     owner "root"
     group "root"
     mode 0755
     action :create
   end

   ##### Enables passwordless rsync accross nodes #####
   rc_home_dir = "/home/#{node[:glance][:rsync_user]}"
   rc_ssh_dir = "#{rc_home_dir}/.ssh"

   # Creates home and ssh directory for rsync user
   Chef::Log.info("Creates ssh dir : #{rc_ssh_dir}")
   directory "#{rc_ssh_dir}" do
     group "glance"
     mode 0700
     recursive true
     action :create
   end

   # Creates rsync user under glance group
   # Removed password since rsync user is supposed to work passwordless
   Chef::Log.info("Creates rsync user")
   user node[:glance][:rsync_user] do
     comment "Glance rsync user"
     gid "glance"
     home "#{rc_home_dir}"
     shell "/bin/bash"
     action :create
   end

   # Change ownership to rsync user
   change_ownership_cmd = "chown -R #{node[:glance][:rsync_user]}:glance  #{rc_home_dir}"
   execute "chmod" do
     command "#{change_ownership_cmd}"
     action :run
   end

   # Change permissions to images directory as rsync can access it
   change_perm_cmd = "chmod g+w #{node[:glance][:filesystem_store_datadir]}"
   Chef::Log.info("Change permissions to images dir with cmd : #{change_perm_cmd}")
   execute "chmod" do
     command "#{change_perm_cmd}"
     action :run
   end

   # Copies ssh authorized keys
   cookbook_file "#{rc_ssh_dir}/authorized_keys" do
     source "authorized_keys"
     owner "#{node[:glance][:rsync_user]}"
     group "glance"
     mode 0644
     action :create
   end

   # Copies ssh id_rsa 
   cookbook_file "#{rc_ssh_dir}/id_rsa" do
     source "id_rsa"
     owner "#{node[:glance][:rsync_user]}"
     group "glance"
     mode 0600
     action :create
   end

   # Creates crontab
   rsync_cron_file = "/var/spool/cron/crontabs/root"
   rsync_cron_rule_file = "#{rc_home_dir}/crontab.txt"
   Chef::Log.info("** Creates crom job for synchronization **")
   # Uploads crontab text file containing sunc rule
   cookbook_file "#{rsync_cron_rule_file}" do
     source "crontab.txt"
     owner "root"
     group "root"
     mode 0755
     action :create
   end

   # Checks if Cron job does not contain image sync script yet since chef server can append it several times 
   execute "rsync cron command" do
      command "crontab #{rsync_cron_rule_file}"
      not_if "grep glance-image-sync #{rsync_cron_file}"
   end
   Chef::Log.info("** End of image sync **")
end

############################# Image Sync end ##########################

glance_path = "/opt/glance"
venv_path = node[:glance][:use_virtualenv] ? "#{glance_path}/.venv" : nil
venv_prefix = node[:glance][:use_virtualenv] ? ". #{venv_path}/bin/activate &&" : nil

if node[:glance][:use_keystone]
  env_filter = " AND keystone_config_environment:keystone-config-#{node[:glance][:keystone_instance]}"
  keystones = search(:node, "recipes:keystone\\:\\:server#{env_filter}") || []
  if keystones.length > 0
    keystone = keystones.first
    keystone = node if keystone.name == node.name
  else
    keystone = node
  end

# keystone_address = Chef::Recipe::Barclamp::Inventory.get_network_by_type(keystone, "admin").address if keystone_address.nil?

  # Keystone address must be admin_vip
  keystone_address = admin_vip

  keystone_token = keystone["keystone"]["service"]["token"]
  Chef::Log.info("keystone token: #{keystone_token}")
 
  keystone_service_port = keystone["keystone"]["api"]["service_port"]
  Chef::Log.info("keystone service port: #{keystone_service_port}")

  keystone_admin_port = keystone["keystone"]["api"]["admin_port"]
  Chef::Log.info("keystone admin port: #{keystone_admin_port}")

  keystone_service_tenant = keystone["keystone"]["service"]["tenant"]
  Chef::Log.info("keystone service tenant: #{keystone_service_tenant}")

  keystone_service_user = node[:glance][:service_user]
  Chef::Log.info("keystone service user: #{keystone_service_user}")

  keystone_service_password = node[:glance][:service_password]
  Chef::Log.info("Keystone service password #{keystone_service_password}") 
  Chef::Log.info("Keystone server found at #{keystone_address}")

  if node[:glance][:use_gitrepo]
    pfs_and_install_deps "keystone" do
      cookbook "keystone"
      cnode keystone
      path File.join(glance_path,"keystone")
      virtualenv venv_path
    end
  end

else
  keystone_address = ""
  keystone_token = ""
  keystone_service_port = ""
  keystone_service_tenant = ""
  keystone_service_user = ""
  keystone_service_password = ""
end

template node[:glance][:api][:config_file] do
  source "glance-api.conf.erb"
  owner node[:glance][:user]
  group "root"
  mode 0644
  variables(
      :keystone_address => keystone_address,
      :keystone_service_port => keystone_service_port,
      :keystone_service_user => keystone_service_user,
      :keystone_service_password => keystone_service_password,
      :keystone_service_tenant => keystone_service_tenant
  )
end

template node[:glance][:api][:paste_ini] do
  source "glance-api-paste.ini.erb"
  owner node[:glance][:user]
  group "root"
  mode 0644
  variables(
    :keystone_address => keystone_address,
    :keystone_auth_token => keystone_token,
    :keystone_service_port => keystone_service_port,
    :keystone_service_user => keystone_service_user,
    :keystone_service_password => keystone_service_password,
    :keystone_service_tenant => keystone_service_tenant,
    :keystone_admin_port => keystone_admin_port
  )
end

bash "Set api glance version control" do
  user "glance"
  group "glance"
  code "exit 0"
  notifies :run, "bash[Sync api glance db]", :immediately
  only_if "#{venv_prefix}glance-manage version_control 0", :user => "glance", :group => "glance"
  action :run
end

bash "Sync api glance db" do
  user "glance"
  group "glance"
  code "#{venv_prefix}glance-manage db_sync"
  action :nothing
end

if node[:glance][:use_keystone]
#  my_admin_ip = Chef::Recipe::Barclamp::Inventory.get_network_by_type(node, "admin").address
#  my_public_ip = Chef::Recipe::Barclamp::Inventory.get_network_by_type(node, "public").address

  my_admin_ip = admin_vip
  my_public_ip = public_vip
  api_port = node["glance"]["api"]["bind_port"]

  keystone_register "glance api wakeup keystone" do
    host keystone_address
    port keystone_admin_port
    token keystone_token
    action :wakeup
  end

  keystone_register "register glance user" do
    host keystone_address
    port keystone_admin_port
    token keystone_token
    user_name keystone_service_user
    user_password keystone_service_password
    tenant_name keystone_service_tenant
    action :add_user
  end

  keystone_register "give glance user access" do
    host keystone_address
    port keystone_admin_port
    token keystone_token
    user_name keystone_service_user
    tenant_name keystone_service_tenant
    role_name "admin"
    action :add_access
  end

  keystone_register "register glance service" do
    host keystone_address
    port keystone_admin_port
    token keystone_token
    service_name "glance"
    service_type "image"
    service_description "Openstack Glance Service"
    action :add_service
  end

  keystone_register "register glance endpoint" do
    host keystone_address
    port keystone_admin_port
    token keystone_token
    endpoint_service "glance"
    endpoint_region "RegionOne"
    endpoint_publicURL "http://#{my_public_ip}:#{api_port}/v1"
    endpoint_adminURL "http://#{my_admin_ip}:#{api_port}/v1"
    endpoint_internalURL "http://#{my_admin_ip}:#{api_port}/v1"
#  endpoint_global true
#  endpoint_enabled true
    action :add_endpoint_template
  end
end

glance_service "api"

node[:glance][:monitor][:svcs] <<["glance-api"]

