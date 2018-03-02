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


export BOOTSTRAP_SCRIPT_URL=$bootstrap_script_url
export BOOTSTRAP_SCRIPT_URL=${BOOTSTRAP_SCRIPT_URL:-https://raw.githubusercontent.com/salt-formulas/salt-formulas-scripts/master/bootstrap.sh}

# inherit heat variables
export RECLASS_ADDRESS=$reclass_address
export RECLASS_BRANCH=$reclass_branch
export RECLASS_ROOT=$reclass_root
export CLUSTER_NAME=$cluster_name
export HOSTNAME=$node_hostname
export DOMAIN=$node_domain
export DISTRIB_REVISION=$formula_pkg_revision
export EXTRA_FORMULAS="$extra_formulas"
# set with default's if not provided at all
export RECLASS_BRANCH=${RECLASS_BRANCH:-master}
export RECLASS_ROOT=${RECLASS_ROOT:-/srv/salt/reclass}
export DISTRIB_REVISION=${DISTRIB_REVISION:-nightly}
#export DEBUG=${DEBUG:-1}

# setup private key
[ ! -d /root/.ssh ] && mkdir -p /root/.ssh
if [ "$private_key" != "" ]; then
cat << 'EOF' > /root/.ssh/id_rsa
$private_key
EOF
chmod 400 /root/.ssh/id_rsa
fi

mkdir -p /srv/salt/scripts
curl -q ${BOOTSTRAP_SCRIPT_URL} -o /srv/salt/scripts/bootstrap.sh
chmod u+x /srv/salt/scripts/bootstrap.sh
source /srv/salt/scripts/bootstrap.sh

system_config_master

clone_reclass || exit 1

source_local_envs

# reclass overrides
mkdir -p ${RECLASS_ROOT}/classes/cluster
cat << EOF > ${RECLASS_ROOT}/classes/cluster/overrides.yml
parameters:
  _param:
    infra_config_address: $node_control_ip
    infra_config_deploy_address: $node_ip
EOF

#bootstrap
cd /srv/salt/scripts
(set -o pipefail && MASTER_HOSTNAME=$node_hostname.$node_domain ./bootstrap.sh 2>&1 | tee /var/log/bootstrap-salt-result.log) ||\
  wait_condition_send "FAILURE" "Command \"MASTER_HOSTNAME=$node_hostname.$node_domain /srv/salt/scripts/bootstrap.sh\" failed. Output: '$(cat /var/log/bootstrap-salt-result.log)'"

# states
echo "Running salt master states ..."
run_states=("linux,openssh" "reclass" "salt.master.service" "salt")
for state in "${run_states[@]}"
do
  salt-call --no-color state.apply "$state" -l info || wait_condition_send "FAILURE" "Salt state $state run failed."
done

salt-call saltutil.sync_all
