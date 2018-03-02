# Required variables:
# nodes_os - operating system (centos7, trusty, xenial)
# node_hostname - hostname of this node (mynode)
# node_domain - domainname of this node (mydomain)
# cluster_name - clustername, used to classify this node (virtual_mcp11_k8s)
# config_host - IP/hostname of salt-master (192.168.0.1)
#
# private_key - SSH private key, used to clone reclass model
# reclass_address - address of reclass model (https://github.com/user/repo.git)
# reclass_branch - branch of reclass model (master)

# inherit heat variables
export CLUSTER_NAME=$cluster_name
export HOSTNAME=$node_hostname
export DOMAIN=$node_domain
export ARCHITECT_PROJECT=$node_domain
# set with default's if not provided at all
export FORMULA_REVISION=${FORMULA_REVISION:-nightly}
export ARCHITECT_PROJECT=${ARCHITECT_PROJECT:-default}
export ARCHITECT_HOST=${ARCHITECT_HOST:-172.16.193.126}
export ARCHITECT_PORT=${ARCHITECT_PORT:-8181}
#export DEBUG=${DEBUG:-1}

echo "Installing base system packages ..."
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends gcc gpgv python-pip python-wheel python-setuptools python-dev


echo "Installing Salt master packages ..."
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends salt-master


echo "Installing Salt master formula packages ..."
echo "deb http://apt.mirantis.com/xenial ${FORMULA_REVISION} salt" | tee /etc/apt/sources.list.d/salt-formulas.list >/dev/null
curl -sL "http://apt.mirantis.com/public.gpg" | $SUDO apt-key add -
apt-get -qq update
DEBIAN_FRONTEND=noninteractive apt-get install -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" salt-formula-* -y --fix-missing
mkdir -p /srv/salt/env/dev

ln -s /usr/share/salt-formulas/env /srv/salt/env/prd

mkdir -p /usr/share/salt-formulas/env/_engines

cat << EOF > /usr/share/salt-formulas/env/_engines/architect.py
# -*- coding: utf-8 -*-
"""
Salt engine for intercepting state jobs and forwarding to the Architect.
"""

# Import python libs
from __future__ import absolute_import
import logging
from architect_client.libarchitect import ArchitectClient

# Import salt libs
import salt.utils.event

logger = logging.getLogger(__name__)


def start(project='default',
          host='127.0.0.1',
          port=8181,
          username=None,
          password=None):
    '''
    Listen to state jobs events and forward state functions and node info
    '''
    state_functions = ['state.sls', 'state.apply', 'state.highstate']
    model_functions = ['architect.node_info']
    class_tag = 'architect/minion/classify'

    if __opts__['__role'] == 'master':
        event_bus = salt.utils.event.get_master_event(__opts__,
                                                      __opts__['sock_dir'],
                                                      listen=True)
    else:
        event_bus = salt.utils.event.get_event(
            'minion',
            transport=__opts__['transport'],
            opts=__opts__,
            sock_dir=__opts__['sock_dir'],
            listen=True)

    logger.info('Architect Engine initialised')

    while True:
        event = event_bus.get_event()
        if event and event.get('fun', None) in state_functions:
            is_test_run = 'test=true' in [arg.lower() for arg in event.get('fun_args', [])]
            if not is_test_run:
                output = ArchitectClient().push_event(event)
                logger.info("Sent Architect state function {}".format(output))
        if event and event.get('fun', None) in model_functions:
            output = ArchitectClient().push_node_info({event['id']: event['return']})
            logger.info("Sent Architect node info function {}".format(output))
        if event and event.get('tag', None) == class_tag:
            output = ArchitectClient().classify_node({
                'name': event['id'],
                'data': event['data']
            })
            logger.info("Sent Architect node classification {}".format(output))
EOF

echo "Getting Salt master address ..."
# Salt master IP addresses
node_ip="$(ip a | awk -v prefix="^    inet $network01_prefix[.]" '$0 ~ prefix {split($2, a, "/"); print a[1]}')"
node_control_ip="$(ip a | awk -v prefix="^    inet $network02_prefix[.]" '$0 ~ prefix {split($2, a, "/"); print a[1]}')"
export MASTER_IP=$node_ip

# mkdir -p /srv/salt/scripts
# curl -q ${BOOTSTRAP_SCRIPT_URL} -o /srv/salt/scripts/bootstrap.sh
# chmod u+x /srv/salt/scripts/bootstrap.sh
# source /srv/salt/scripts/bootstrap.sh


echo "Installing and configing Architect client ..."
pip install architect-client
mkdir -p /etc/architect
cat << EOF > /etc/architect/client.yml
project: ${ARCHITECT_PROJECT}
host: ${ARCHITECT_HOST}
port: ${ARCHITECT_PORT}
EOF


echo "Creating Salt master configuration ..."
cat << EOF > /etc/salt/master.d/master.conf
worker_threads: 10
timeout: 60
state_output: changes
file_roots:
  base:
  - /srv/salt/env/prd
  prd:
  - /srv/salt/env/prd
pillar_opts: False
auto_accept: True
ext_pillar:
  - cmd_yaml: 'architect-salt-pillar %s'
master_tops:
  ext_nodes: architect-salt-top
EOF
service salt-master restart


echo "Creating Architect inventory ..."
architect-inventory-create ${CLUSTER_NAME} ${DOMAIN}
sleep 10


echo "Preparing Salt minion for first run ..."
salt-call saltutil.sync_all
salt-call saltutil.refresh_pillar


echo "Applying Salt minion states ..."
run_master_states=("linux" "openssh" "salt.master.service" "salt.minion.ca" "salt.minion.cert" "salt.api" "salt.minion" "reclass")
for state in "${run_master_states[@]}"
do
  salt-call --no-color state.apply "$state" -l info || wait_condition_send "FAILURE" "Salt state $state run failed."
done


echo "Creating Architect manager ..."
architect-manager-salt-create ${ARCHITECT_PROJECT} http://${PUBLIC_IP}:6969 salt 'hovno12345!'
sleep 10
