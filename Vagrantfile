# -*- mode: ruby -*-
# vi: set ft=ruby :
#
# Disposable test VM for the public installer (see tests/e2e/vagrant-install.sh).
#
#   VAGRANT_BOX=ubuntu/noble64 tests/e2e/vagrant-install.sh --reboot-test
#   VAGRANT_BOX=debian/bookworm64 tests/e2e/vagrant-install.sh

VAGRANT_BOX = ENV.fetch("VAGRANT_BOX", "ubuntu/noble64")

# Host-side ports used to reach the guest after hardening (mainly for
# VirtualBox, where the guest is only reachable through forwarded ports).
E2E_HOST_PORT_VAGRANT_SSH = ENV.fetch("E2E_HOST_PORT_VAGRANT_SSH", 2223)
E2E_HOST_PORT_ADMIN_SSH   = ENV.fetch("E2E_HOST_PORT_ADMIN_SSH", 2222)
E2E_HOST_PORT_WG_UDP      = ENV.fetch("E2E_HOST_PORT_WG_UDP", 51820)
E2E_HOST_PORT_WG_UI       = ENV.fetch("E2E_HOST_PORT_WG_UI", 51821)
E2E_HOST_PORT_ADGUARD_UI  = ENV.fetch("E2E_HOST_PORT_ADGUARD_UI", 3000)

Vagrant.configure("2") do |config|
  config.vm.box = VAGRANT_BOX
  config.vm.hostname = "ztvps-test"

  config.vm.synced_folder ".", "/vagrant", type: "rsync"

  config.vm.provider "libvirt" do |lv|
    lv.memory = 2048
    lv.cpus = 2
  end
  config.vm.provider "virtualbox" do |vb|
    vb.memory = 2048
    vb.cpus = 2
  end

  config.vm.network "forwarded_port", guest: 22,    host: E2E_HOST_PORT_VAGRANT_SSH, id: "ssh", auto_correct: true
  config.vm.network "forwarded_port", guest: 2222,  host: E2E_HOST_PORT_ADMIN_SSH,   id: "admin-ssh", auto_correct: true
  config.vm.network "forwarded_port", guest: 51820, host: E2E_HOST_PORT_WG_UDP,      id: "wg", protocol: "udp", auto_correct: true
  config.vm.network "forwarded_port", guest: 51821, host: E2E_HOST_PORT_WG_UI,       id: "wg-ui", auto_correct: true
  config.vm.network "forwarded_port", guest: 3000,  host: E2E_HOST_PORT_ADGUARD_UI,  id: "adguard-ui", auto_correct: true
end
