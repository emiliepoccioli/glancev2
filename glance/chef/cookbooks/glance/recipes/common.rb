#
# Cookbook Name:: glance
# Recipe:: common
#
# Copyright 2011 Opscode, Inc.
# Copyright 2011 Rackspace, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

Chef::Log.info(">>>>>> Glance: Common Recipe")

##################################### Ha code #######################################
# Retrieve virtual ip addresses from LoadBalancer
admin_vip = node[:haproxy][:admin_ip]
public_vip = node[:haproxy][:public_ip]
db_root_password = node["percona"]["server_root_password"]

Chef::Log.info(">>>>>> Glance: Common Recipe admin vip: #{admin_vip}")
Chef::Log.info(">>>>>> Glance: Common Recipe public vip: #{public_vip}")
Chef::Log.info(">>>>>> Glance: Common Recipe db root password: #{db_root_password}")

## Set API and Registry bind address to false not to use 0.0.0.0 as endpoints 
node.set[:glance][:api][:bind_open_address] = false
node.set[:glance][:registry][:bind_open_address] = false

# Set Glance Service Credentials (Authentication against Keystone)
# There are set by default in data bags json file
node.set_unless[:glance][:service_user] = "glance"
node.set_unless[:glance][:service_password] = "glance"


######################################################################################

glance_path = "/opt/glance"
venv_path = node[:glance][:use_virtualenv] ? "#{glance_path}/.venv" : nil
venv_prefix = node[:glance][:use_virtualenv] ? ". #{venv_path}/bin/activate &&" : nil

package "curl" do
  action :install
end

unless node[:glance][:use_gitrepo]
  package "python-keystone" do
    action :install
  end
  package "glance" do
    package_name "openstack-glance" if node.platform == "suse"
    options "--force-yes" if node.platform != "suse"
    action :install
  end
else

  pfs_and_install_deps @cookbook_name do
    virtualenv venv_path
    wrap_bins [ "glance" ]
  end

  create_user_and_dirs("glance")
  execute "cp_.json_#{@cookbook_name}" do
    command "cp #{glance_path}/etc/*.json /etc/#{@cookbook_name}"
    creates "/etc/#{@cookbook_name}/policy.json"
  end

  link_service "glance-api" do
    virtualenv venv_path
  end

  link_service "glance-registry" do
    virtualenv venv_path
  end

end

######################## DATABASE OPERATIONS #################################
Chef::Log.info(">>>>>> Glance: Common Recipe: Database operations")

# Make sure we use the admin node for now.
my_ipaddress = Chef::Recipe::Barclamp::Inventory.get_network_by_type(node, "admin").address
node[:glance][:api][:bind_host] = my_ipaddress
node[:glance][:registry][:bind_host] = my_ipaddress

Chef::Log.info(">>>>>> Glance: bind ip address : #{my_ipaddress}")
sql_address = admin_vip
url_scheme = "mysql"

::Chef::Recipe.send(:include, Opscode::OpenSSL::Password)

#node.set_unless['glance']['db']['password'] = secure_password
node.set_unless['glance']['db']['password'] = "glance" 
node.set_unless['glance']['db']['user'] = "glance"
node.set_unless['glance']['db']['database'] = "glance"

Chef::Log.info("Database server found at #{sql_address}")

############## MySQL operations done with a template file ################ 
# create Glance database & user, and grant privileges
template "/tmp/glance_grants.sql" do
  source "glance_grants.sql.erb"
  mode 0600
  variables(
    :glance_db_name => node[:glance][:db][:database],
    :glance_db_user => node[:glance][:db][:user],
    :glance_db_user_pwd => node[:glance][:db][:password]
  )
end
# execute access grants
execute "mysql-install-privileges" do
  command "/usr/bin/mysql -u root -p#{db_root_password} < /tmp/glance_grants.sql"
  action :nothing
  subscribes :run, resources("template[/tmp/glance_grants.sql]"), :immediately
end

  node[:glance][:sql_connection] = "#{url_scheme}://#{node[:glance][:db][:user]}:#{node[:glance][:db][:password]}@#{sql_address}/#{node[:glance][:db][:database]}"

# Removes SQLite file as we are using MySQL
file "/var/lib/glance/glance.sqlite" do
  action :delete
end

############################################################################
node.save

