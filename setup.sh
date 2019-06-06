#!/bin/bash

# Install using: curl https://raw.githubusercontent.com/nobitagamer/ubuntu-server-setup/master/setup.sh -o /tmp/setup.sh && bash /tmp/setup.sh

set -e

function getCurrentDir() {
  local current_dir="${BASH_SOURCE%/*}"
  if [[ ! -d "${current_dir}" ]]; then current_dir="$PWD"; fi
  echo "${current_dir}"
}

# function includeDependencies() {
#     # shellcheck source=./setupLibrary.sh
#     source "${current_dir}/setupLibrary.sh"
# }

# ==================================================================
#   DEPENDENCIES
# ==================================================================

# Add the new user account
# Arguments:
#   Account Username
#   Account Password
#   Flag to determine if user account is added silently. (With / Without GECOS prompt)
function addUserAccount() {
  local username=${1}
  local password=${2}
  local silent_mode=${3}

  if [[ ${silent_mode} == "true" ]]; then
    sudo adduser --disabled-password --gecos '' "${username}"
  else
    sudo adduser --disabled-password "${username}"
  fi

  echo "${username}:${password}" | sudo chpasswd
  sudo usermod -aG sudo "${username}"
}

# Add the local machine public SSH Key for the new user account
# Arguments:
#   Account Username
#   Public SSH Key
function addSSHKey() {
  local username=${1}
  local sshKey=${2}

  execAsUser "${username}" "mkdir -p ~/.ssh; chmod 700 ~/.ssh; touch ~/.ssh/authorized_keys"
  execAsUser "${username}" "echo \"${sshKey}\" | sudo tee -a ~/.ssh/authorized_keys"
  execAsUser "${username}" "chmod 600 ~/.ssh/authorized_keys"
}

# Execute a command as a certain user
# Arguments:
#   Account Username
#   Command to be executed
function execAsUser() {
  local username=${1}
  local exec_command=${2}

  sudo -u "${username}" -H bash -c "${exec_command}"
}

# Modify the sshd_config file
# shellcheck disable=2116
function changeSSHConfig() {
  echo "Modify the sshd_config file..."
  sudo sed -re 's/^(\#?)(PasswordAuthentication)([[:space:]]+)yes/\2\3no/' -i."$(echo 'old')" /etc/ssh/sshd_config

  # Allow root login to use with Ansible
  sudo sed -re 's/^(\#?)(PermitRootLogin)([[:space:]]+)(.*)/PermitRootLogin yes/' -i /etc/ssh/sshd_config
  # sudo sed -re 's/^(\#?)(PermitRootLogin)([[:space:]]+)(.*)/PermitRootLogin no/' -i /etc/ssh/sshd_config
}

# Setup the Uncomplicated Firewall
function setupUfw() {
  echo "Setup the Uncomplicated Firewall..."
  sudo ufw allow OpenSSH
  yes y | sudo ufw enable
}

# Create the swap file based on amount of physical memory on machine (Maximum size of swap is 4GB)
function createSwap() {
  local swapmem=$(($(getPhysicalMemory) * 2))

  # Anything over 4GB in swap is probably unnecessary as a RAM fallback
  if [ ${swapmem} -gt 4 ]; then
    swapmem=4
  fi

  sudo fallocate -l "${swapmem}G" /swapfile
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile
  sudo swapon /swapfile
}

# Mount the swapfile
function mountSwap() {
  sudo cp /etc/fstab /etc/fstab.bak
  echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
}

# Modify the swapfile settings
# Arguments:
#   new vm.swappiness value
#   new vm.vfs_cache_pressure value
function tweakSwapSettings() {
  local swappiness=${1}
  local vfs_cache_pressure=${2}

  sudo sysctl vm.swappiness="${swappiness}"
  sudo sysctl vm.vfs_cache_pressure="${vfs_cache_pressure}"
}

# Save the modified swap settings
# Arguments:
#   new vm.swappiness value
#   new vm.vfs_cache_pressure value
function saveSwapSettings() {
  local swappiness=${1}
  local vfs_cache_pressure=${2}

  echo "vm.swappiness=${swappiness}" | sudo tee -a /etc/sysctl.conf
  echo "vm.vfs_cache_pressure=${vfs_cache_pressure}" | sudo tee -a /etc/sysctl.conf
}

# Set the machine's timezone
# Arguments:
#   tz data timezone
function setTimezone() {
  local timezone=${1}
  echo "${1}" | sudo tee /etc/timezone
  sudo ln -fs "/usr/share/zoneinfo/${timezone}" /etc/localtime # https://bugs.launchpad.net/ubuntu/+source/tzdata/+bug/1554806
  sudo dpkg-reconfigure -f noninteractive tzdata
}

# Configure Network Time Protocol
function configureNTP() {
  sudo apt-get update
  sudo apt-get --assume-yes install ntp
}

# Gets the amount of physical memory in GB (rounded up) installed on the machine
function getPhysicalMemory() {
  local phymem
  phymem="$(free -g | awk '/^Mem:/{print $2}')"

  if [[ ${phymem} == '0' ]]; then
    echo 1
  else
    echo "${phymem}"
  fi
}

# Disables the sudo password prompt for a user account by editing /etc/sudoers
# Arguments:
#   Account username
function disableSudoPassword() {
  local username="${1}"

  # sudo cp /etc/sudoers /etc/sudoers.bak
  if ! sudo grep "${1} ALL=(ALL) NOPASSWD" /etc/sudoers > /dev/null; then
    sudo bash -c "echo '${1} ALL=(ALL) NOPASSWD: ALL' | (EDITOR='tee -a' visudo)"
  fi
}

# Reverts the original /etc/sudoers file before this script is ran
function revertSudoers() {
  sudo cp /etc/sudoers.bak /etc/sudoers
  sudo rm -rf /etc/sudoers.bak
}

# Use MPS mirrors
function useMpsMirror() {
  if ! grep "repo-mps" /etc/apt/sources.list > /dev/null; then
    echo "Adding MPS mirrors..." setupTimezone >&3
    sudo sed '/bionic main restricted/{s/^/#/}' -i."$(echo 'old')" /etc/apt/sources.list
    sudo sed '/bionic-updates main restricted/{s/^/#/}' -i."$(echo 'old')" /etc/apt/sources.list
    sudo tee -a /etc/apt/sources.list > /dev/null << EOL
deb https://repo-mps.mto.zing.vn/ubuntu/ bionic main restricted
deb https://repo-mps.mto.zing.vn/ubuntu/ bionic-updates main restricted
EOL
  fi
}

# ==================================================================

current_dir=$(getCurrentDir)
# includeDependencies
output_file="output.log"

function main() {
  read -rp "Enter the new host name:" hostname
  read -rp "Enter static IP for server (VMWare host: 192.168.13.1):" ip
  read -rp "Enter gateway IP (VMWare gateway: 192.168.13.2):" gateway
  read -rp "Enter the username of the new user account:" username
  read -rp $'Paste in the public SSH key for the new user:\n' sshKey

  # Run setup functions
  trap cleanup EXIT SIGHUP SIGINT SIGTERM

  if [ ! -z "${username}" ]; then
    if ! id -u "${username}" > /dev/null; then
      promptForPassword
      addUserAccount "${username}" "${password}" "true"
    else
      echo "User '${username}' already exist!"
    fi

    disableSudoPassword "${username}"
    if [ ! -z "${sshKey}" ]; then
      addSSHKey "${username}" "${sshKey}"
    fi
  fi

  echo 'Running setup script...'
  logTimestamp "${output_file}"

  exec 3>&1 >>"${output_file}" 2>&1

  setupTimezone

  if [ ! -z "${ip}" ]; then
    sudo cp /etc/netplan/50-cloud-init.yaml /etc/netplan/50-cloud-init.yaml.bak
    sudo tee -a /etc/netplan/50-cloud-init.yaml > /dev/null << EOL
network:
    ethernets:
        ens32:
            addresses:
            - ${ip}/24
            gateway4: ${gateway}
            nameservers:
                addresses: [8.8.8.8, 8.8.4.4]
            optional: true
    version: 2
EOL
    sudo netplan --debug apply >&3
  fi
  
  if [ ! -z "${hostname}" ]; then
    sudo sudo hostnamectl set-hostname "${hostname}"
  fi

  # Update packages using MPS mirrors
  useMpsMirror
  sudo apt update >&3
  sudo apt upgrade -y >&3
  sudo apt update >&3
  sudo apt install -y python >&3

  # Install SSH server
  if ! service ssh status; then
    sudo rm -f /etc/ssh/ssh_host_*
    sudo apt install openssh-server -y
    test -f /etc/ssh/ssh_host_dsa_key || sudo dpkg-reconfigure --force openssh-server
  fi

  changeSSHConfig
  setupUfw

  if ! hasSwap; then
    setupSwap
  fi

  echo "Installing Network Time Protocol... " >&3
  configureNTP

  sudo service ssh restart

  # cleanup
  # Pesist sudoers
  if [[ -f "/etc/sudoers.bak" ]]; then
    sudo rm -rf /etc/sudoers.bak
  fi

  echo "Setup Done! Log file is located at ${output_file}" >&3
}

function setupSwap() {
  createSwap
  mountSwap
  tweakSwapSettings "10" "50"
  saveSwapSettings "10" "50"
}

function hasSwap() {
  [[ "$(sudo swapon -s)" == *"/swapfile"* ]]
}

function cleanup() {
  if [[ -f "/etc/sudoers.bak" ]]; then
    revertSudoers
  fi
}

function logTimestamp() {
  local filename=${1}
  {
    echo "==================="
    echo "Log generated on $(date)"
    echo "==================="
  } >>"${filename}" 2>&1
}

function setupTimezone() {
  echo -ne "Enter the timezone for the server (Default is 'Asia/Ho_Chi_Minh'):\n" >&3
  read -r timezone
  if [ -z "${timezone}" ]; then
    timezone="Asia/Ho_Chi_Minh"
  fi
  setTimezone "${timezone}"
  echo "Timezone is set to $(cat /etc/timezone)" >&3
}

# Keep prompting for the password and password confirmation
function promptForPassword() {
  PASSWORDS_MATCH=0
  while [ "${PASSWORDS_MATCH}" -eq "0" ]; do
    read -s -rp "Enter new UNIX password:" password
    printf "\n"
    read -s -rp "Retype new UNIX password:" password_confirmation
    printf "\n"

    if [[ "${password}" != "${password_confirmation}" ]]; then
      echo "Passwords do not match! Please try again."
    else
      PASSWORDS_MATCH=1
    fi
  done
}

main
