#!/bin/bash

#--------------------------------------------------------------
# Variables
#--------------------------------------------------------------
ADMIN_PASSWORD=secret
HOST_IP=`ifconfig enp0s8 2>/dev/null|awk '/inet addr:/ {print $2}'|sed 's/addr://'`
HOSTNAME=`hostname`
#--------------------------------------------------------------

#--------------------------------------------------------------
# System update and tune
#--------------------------------------------------------------
sudo apt-get update
#--------------------------------------------------------------

#--------------------------------------------------------------
# SWAP File
#--------------------------------------------------------------
# size of swapfile in megabytes

swapsize=4000

# does the swap file already exist?
grep -q "swapfile" /etc/fstab

# if not then create it
if [ $? -ne 0 ]; then
  echo 'swapfile not found. Adding swapfile.'
  fallocate -l ${swapsize}M /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap defaults 0 0' >> /etc/fstab
else
  echo 'swapfile found. No changes made.'
fi

# output results to terminal
df -h
cat /proc/swaps
cat /proc/meminfo | grep Swap
#--------------------------------------------------------------


#--------------------------------------------------------------
# MCP AIO Install
#--------------------------------------------------------------

wget -O - https://repo.saltstack.com/apt/ubuntu/16.04/amd64/2016.3/SALTSTACK-GPG-KEY.pub | sudo apt-key add -
add-apt-repository http://repo.saltstack.com/apt/ubuntu/16.04/amd64/2016.3
apt update
apt install -y salt-master salt-minion reclass make

rm /etc/salt/minion_id
rm -f /etc/salt/pki/minion/minion_master.pub
echo "id: $HOSTNAME.local" > /etc/salt/minion
echo "master: localhost" >> /etc/salt/minion

[ ! -d /etc/salt/master.d ] && mkdir -p /etc/salt/master.d
cat <<-EOF > /etc/salt/master.d/master.conf
file_roots:
  base:
  - /usr/share/salt-formulas/env
pillar_opts: False
open_mode: True
reclass: &reclass
  storage_type: yaml_fs
  inventory_base_uri: /srv/salt/reclass
ext_pillar:
  - reclass: *reclass
master_tops:
  reclass: *reclass
EOF

[ ! -d /etc/reclass ] && mkdir /etc/reclass
cat <<-EOF > /etc/reclass/reclass-config.yml
storage_type: yaml_fs
pretty_print: True
output: yaml
inventory_base_uri: /srv/salt/reclass
EOF

service salt-master restart
service salt-minion restart

git clone https://gerrit.mcp.mirantis.net/p/salt-models/mcp-virtual-aio.git /srv/salt/reclass
cd /srv/salt/reclass
git clone https://gerrit.mcp.mirantis.net/p/salt-models/reclass-system.git classes/system
ln -s /usr/share/salt-formulas/reclass/service classes/service

export FORMULAS_BASE=https://gerrit.mcp.mirantis.net/salt-formulas
export FORMULAS_PATH=/root/formulas
export FORMULAS_BRANCH=master

mkdir -p ${FORMULAS_PATH}
declare -a formula_services=("linux" "reclass" "salt" "openssh" "ntp" "git" "nginx" "collectd" "sensu" "heka" "sphinx" "mysql" "grafana" "libvirt" "rsyslog" "memcached" "rabbitmq" "apache" "keystone" "glance" "nova" "neutron" "cinder" "heat" "horizon" "ironic" "tftpd-hpa" "bind" "powerdns" "designate")
for formula_service in "${formula_services[@]}"; do
  _BRANCH=${FORMULAS_BRANCH}
    [ ! -d "${FORMULAS_PATH}/${formula_service}" ] && {
      if ! git ls-remote --exit-code --heads ${FORMULAS_BASE}/${formula_service}.git ${_BRANCH};then
        # Fallback to the master branch if the branch doesn't exist for this repository
        _BRANCH=master
      fi
      git clone ${FORMULAS_BASE}/${formula_service}.git ${FORMULAS_PATH}/${formula_service} -b ${_BRANCH}
    } || {
      cd ${FORMULAS_PATH}/${formula_service};
      git fetch ${_BRANCH} || git fetch --all
      git checkout ${_BRANCH} && git pull || git pull;
      cd -
  }
  cd ${FORMULAS_PATH}/${formula_service}
  make install
  cd -
done

# In case Designate should be deployed with PowerDNS backend, change designate_backend.yml:
cat <<-'EOF' > classes/cluster/designate_backend.yml
classes:
- system.designate.server.backend.pdns
parameters:
  _param:
    designate_pool_target_type: pdns4
    powerdns_webserver_password: gJ6n3gVaYP8eS
    powerdns_webserver_port: 8081
    designate_pdns_api_key: VxK9cMlFL5Ae
    designate_pdns_api_endpoint: "http://${_param:single_address}:${_param:powerdns_webserver_port}"
    designate_pool_target_options:
      api_endpoint: ${_param:designate_pdns_api_endpoint}
      api_token: ${_param:designate_pdns_api_key}
  powerdns:
    server:
      axfr_ips:
        - ${_param:single_address}
EOF

# Apply all
#salt-call state.apply # minimum two times or until success

# or apply one by one (when fail on some step - repeat or ignore):
salt-call state.apply salt
salt-call state.apply linux,ntp,openssh
salt-call state.apply memcached
salt-call state.apply rabbitmq
salt-call state.apply mysql
salt-call state.apply keystone
salt-call state.apply glance
salt-call state.apply neutron
salt-call state.apply nova
salt-call state.apply cinder
salt-call state.apply heat
salt-call state.apply horizon

#If Powerdns Designate backend:
#salt-call state.apply powerdns

#If Bind9 Designate backend:
salt-call state.apply bind

salt-call state.apply designate
# Ironic is not available yet.
#salt-call state.apply ironic
#salt-call state.apply tftpd_hpa

service apache2 restart


. /root/keystonercv3

wget http://download.cirros-cloud.net/0.3.5/cirros-0.3.5-x86_64-disk.img
glance image-create --name cirros --visibility public --disk-format qcow2 --container-format bare --file cirros-0.3.5-x86_64-disk.img --progress

neutron net-create internal_net
neutron subnet-create --name internal_subnet internal_net 192.168.1.0/24

neutron net-create external_network --provider:network_type flat --provider:physical_network physnet1 --router:external
neutron subnet-create --name external_subnet --enable_dhcp=False --allocation-pool=start=172.16.1.2,end=172.16.1.250 --gateway=172.16.1.1 external_network 172.16.1.0/24

neutron router-create r1
neutron router-interface-add r1 internal_subnet
neutron router-gateway-set r1 external_network

nova secgroup-add-rule default icmp -1 -1 0.0.0.0/0
nova secgroup-add-rule default tcp 1 65535 0.0.0.0/0

nova flavor-create m1.extra_tiny auto 256 0 1

nova boot --flavor m1.extra_tiny --image cirros --nic net-id=d23f9845-cbce-47a6-be15-0603f6a31365 test # UUID of internal network

nova floating-ip-create external_network
nova floating-ip-associate test 172.16.1.7 # floating IP

cinder create --name test 1
nova volume-attach test 49a471ec-2e6d-4810-9161-6c191e1370f5 # UUID of volume

openstack dns service list
openstack zone create --email dnsmaster@example.tld example.tld.
openstack recordset create --records '10.0.0.1' --type A example.tld. www
nslookup www.example.tld 127.0.0.1

# Horizon is available on port :8078
#--------------------------------------------------------------
