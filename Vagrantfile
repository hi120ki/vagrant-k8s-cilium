Vagrant.configure("2") do |config|
  config.vm.box = "ubuntu/jammy64"

  config.vm.network "public_network", bridge: "eth0", netmask: "16", ip: "10.1.10.7"

  config.vm.synced_folder ".", "/vagrant", SharedFoldersEnableSymlinksCreate: false

  config.vm.provider "virtualbox" do |vb|
    vb.cpus = 4
    vb.memory = 4096
  end

  if Vagrant.has_plugin?("vagrant-vbguest")
    config.vbguest.auto_update = false
  end
  config.vm.provision "shell", privileged: false, inline: <<-SHELL
    bash -eu /vagrant/install.sh 10.1.10.7 enp0s8 10.1.13.1 10.1.13.254
    cilium connectivity test
    bash -eu /vagrant/test.sh
  SHELL
end
