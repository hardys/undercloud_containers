#!/usr/bin/env bash
set -x

sudo setenforce permissive

# Uncomment this for quickstack.
# FIXME: This breaks can break non-quickstack environments...
# Workaround https://bugs.launchpad.net/tripleo-quickstart/+bug/1658030
#if [ ! -f /usr/libexec/os-apply-config/templates/var/run/heat-config/heat-config ]; then
  #sudo yum clean all
  #sudo yum -y reinstall python-heat-agent
#fi

sudo yum -y install curl vim-enhanced telnet epel-release ruby rubygems yum-plugins-priorities deltarpm
sudo yum -y install https://dprince.fedorapeople.org/tmate-2.2.1-1.el7.centos.x86_64.rpm

sudo gem install lolcat

# for tripleo-repos install:
sudo yum -y install python-setuptools python-requests

cd
git clone https://git.openstack.org/openstack/tripleo-repos
cd tripleo-repos
sudo python setup.py install
cd
sudo tripleo-repos current

sudo yum -y update

# these avoid warning for the cherry-picks below ATM
if [ ! -f $HOME/.gitconfig ]; then
  git config --global user.email "theboss@foo.bar"
  git config --global user.name "TheBoss"
fi

sudo yum clean all
sudo yum install -y \
  python-heat-agent \
  python-heat-agent-ansible \
  python-heat-agent-hiera \
  python-heat-agent-apply-config \
  python-heat-agent-docker-cmd \
  python-heat-agent-json-file \
  python-heat-agent-puppet python-ipaddr \
  python-tripleoclient \
  docker \
  docker-distribution \
  openvswitch \
  openstack-tripleo-common \
  openstack-tripleo-heat-templates \
  openstack-puppet-modules \
  openstack-heat-monolith #required as we now use --heat-native
cd

sudo systemctl start openvswitch
sudo systemctl enable openvswitch

sudo mkdir -p /etc/puppet/modules/
sudo ln -f -s /usr/share/openstack-puppet/modules/* /etc/puppet/modules/
sudo mkdir -p /etc/puppet/hieradata/
sudo tee /etc/puppet/hieradata/docker_setup.yaml /etc/puppet/hiera.yaml <<-EOF_CAT
---
:backends:
  - yaml
:yaml:
  :datadir: /etc/puppet/hieradata
:hierarchy:
  - docker_setup
EOF_CAT

echo "step: 5" | sudo tee /etc/puppet/hieradata/docker_setup.yaml
if [ -n "$LOCAL_REGISTRY" ]; then
  echo "tripleo::profile::base::docker::insecure_registry_address: $LOCAL_REGISTRY" | sudo tee -a /etc/puppet/hieradata/docker_setup.yaml
fi

cd
sudo puppet apply --modulepath /etc/puppet/modules --execute "include ::tripleo::profile::base::docker"

# PYTHON TRIPLEOCLIENT
if [ ! -d $HOME/python-tripleoclient ]; then
  git clone git://git.openstack.org/openstack/python-tripleoclient
  cd python-tripleoclient

  # Generate undercloud-passwords.conf and fix output dir.
  # https://review.openstack.org/#/c/523511/
  git fetch https://git.openstack.org/openstack/python-tripleoclient refs/changes/11/523511/11 && git cherry-pick FETCH_HEAD

  # Configure undercloud docker registry/mirror
  # https://review.openstack.org/#/c/526147/
  git fetch https://git.openstack.org/openstack/python-tripleoclient refs/changes/47/526147/5 && git cherry-pick FETCH_HEAD

  # Undercloud: wire in scheduler_max_attempts
  # https://review.openstack.org/#/c/526584/
  git fetch https://git.openstack.org/openstack/python-tripleoclient refs/changes/84/526584/1 && git cherry-pick FETCH_HEAD

  # undercloud_deploy: add opts to setup virtual-ips
  # https://review.openstack.org/#/c/526879/
  git fetch https://git.openstack.org/openstack/python-tripleoclient refs/changes/79/526879/2 && git cherry-pick FETCH_HEAD

  # undercloud_config: setup VIPs, haproxy, etc
  # https://review.openstack.org/#/c/526881/
  git fetch https://git.openstack.org/openstack/python-tripleoclient refs/changes/81/526881/2 && git cherry-pick FETCH_HEAD

  sudo python setup.py install
  cd
fi

# TRIPLEO-COMMON
if [ ! -d $HOME/tripleo-common ]; then
  git clone git://git.openstack.org/openstack/tripleo-common
  cd tripleo-common

  sudo python setup.py install
  cd
fi

# TRIPLEO HEAT TEMPLATES
if [ ! -d $HOME/tripleo-heat-templates ]; then
  cd
  git clone git://git.openstack.org/openstack/tripleo-heat-templates

  cd tripleo-heat-templates

  # Add docker-registry service
  # https://review.openstack.org/#/c/526132/
  git fetch https://git.openstack.org/openstack/tripleo-heat-templates refs/changes/32/526132/3 && git cherry-pick FETCH_HEAD

  # Add tls roles for undercloud
  # https://review.openstack.org/#/c/517079/
  git fetch https://git.openstack.org/openstack/tripleo-heat-templates refs/changes/79/517079/8 && git cherry-pick FETCH_HEAD

  # Add NovaSchedulerMaxAttempts parameter
  # https://review.openstack.org/#/c/526582/
  git fetch https://git.openstack.org/openstack/tripleo-heat-templates refs/changes/82/526582/1 && git cherry-pick FETCH_HEAD

  # tripleo ui docker
  # https://review.openstack.org/#/c/515490/
  # git fetch https://git.openstack.org/openstack/tripleo-heat-templates refs/changes/90/515490/1 && git cherry-pick FETCH_HEAD

  cd
fi

# Puppet TripleO
# if [ ! -d $HOME/puppet-tripleo ]; then
#   cd
#   git clone git://git.openstack.org/openstack/puppet-tripleo
#   cd puppet-tripleo

#   cd /usr/share/openstack-puppet/modules
#   sudo rm -Rf tripleo
#   sudo cp -a $HOME/puppet-tripleo tripleo
# fi

# this is how you inject an admin password
cat > $HOME/tripleo-undercloud-passwords.yaml <<-EOF_CAT
parameter_defaults:
  AdminPassword: HnTzjCGP6HyXmWs9FzrdHRxMs
EOF_CAT

# Custom settings can go here
if [[ ! -f $HOME/custom.yaml ]]; then
cat > $HOME/custom.yaml <<-EOF_CAT
parameter_defaults:
  UndercloudNameserver: 8.8.8.8
  NeutronServicePlugins: ""
  DockerPuppetProcessCount: 100
EOF_CAT
fi

LOCAL_IP=${LOCAL_IP:-`/usr/sbin/ip -4 route get 8.8.8.8 | awk {'print $7'} | tr -d '\n'`}
DEFAULT_ROUTE=${DEFAULT_ROUTE:-`/usr/sbin/ip -4 route get 8.8.8.8 | awk {'print $3'} | tr -d '\n'`}
NETWORK_CIDR=${NETWORK_CIDR:-`echo $DEFAULT_ROUTE/16`}
LOCAL_INTERFACE=${LOCAL_INTERFACE:-`route -n | grep "^0.0.0.0" | tr -s ' ' | cut -d ' ' -f 8 | head -n 1`}

# run this to cleanup containers and volumes between iterations
cat > $HOME/cleanup.sh <<-EOF_CAT
#!/usr/bin/env bash
set -x

sudo docker ps -qa | xargs sudo docker rm -f
sudo docker volume ls -q | xargs sudo docker volume rm
sudo rm -Rf /var/lib/mysql
sudo rm -Rf /var/lib/rabbitmq
sudo rm -Rf /var/lib/heat-config/*
EOF_CAT
chmod 755 $HOME/cleanup.sh

if which lolcat &> /dev/null; then
  cat=lolcat
else
  cat=cat
fi

# FIXME how to generate tripleo-heat-templates/environments/config-download-environment.yaml?
cat > $HOME/run.sh <<-EOF_CAT
export THT_HOME=$HOME/tripleo-heat-templates
time openstack undercloud install --use-heat \\
| tee openstack_undercloud_deploy.out | $cat
EOF_CAT
chmod 755 $HOME/run.sh

# FIXME: It's probably not always /8
cat > $HOME/undercloud.conf <<-EOF_CAT
[DEFAULT]
heat_native=true
local_ip=$LOCAL_IP/8
local_interface=$LOCAL_INTERFACE
network_cidr=$NETWORK_CIDR
network_gateway=$DEFAULT_ROUTE
enable_ironic=true
enable_ironic_inspector=true
enable_zaqar=true
enable_mistral=true
custom_env_files=$HOME/containers.yaml
EOF_CAT

# The current state of the world is:
#  - This one works and is being pushed to:
#openstack overcloud container image prepare --tag tripleo-ci-testing --namespace trunk.registry.rdoproject.org/master --env-file $HOME/containers-rdo.yaml
#  - This one doesn't work but it should (apparently auth issues):
#openstack overcloud container image prepare --tag passed-ci --namespace trunk.registry.rdoproject.org/master --env-file $HOME/containers-rdo.yaml
#  - This one works:
#openstack overcloud container image prepare --namespace=172.19.0.2:8787/tripleoupstream --env-file=$HOME/containers.yaml

openstack overcloud container image prepare \
  --tag tripleo-ci-testing \
  --namespace trunk.registry.rdoproject.org/master \
  --output-env-file=$HOME/containers.yaml \
  --template-file $HOME/tripleo-common/container-images/overcloud_containers.yaml.j2 \
  -r $HOME/tripleo-heat-templates/roles_data_undercloud.yaml \
  -e $HOME/tripleo-heat-templates/environments/docker.yaml \
  -e $HOME/tripleo-heat-templates/environments/services-docker/mistral.yaml \
  -e $HOME/tripleo-heat-templates/environments/services-docker/ironic.yaml \
  -e $HOME/tripleo-heat-templates/environments/services-docker/ironic-inspector.yaml \
  -e $HOME/tripleo-heat-templates/environments/services-docker/zaqar.yaml

set +x

echo 'You will want to add "OS::TripleO::Undercloud::Net::SoftwareConfig: ../net-config-noop.yaml" to tripleo-heat-templates/environments/undercloud.yaml if you have a single nic.'

echo 'The next step is to run ~/run.sh, which will create a heat deployment of your templates.'
