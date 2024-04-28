Vagrant.configure("2") do |config|
  config.vm.box = "ubuntu/jammy64"

  config.vm.network "private_network", ip: "192.168.56.10"

  config.vm.synced_folder ".", "/vagrant", SharedFoldersEnableSymlinksCreate: false

  config.vm.provider "virtualbox" do |vb|
    vb.cpus = 4
    vb.memory = 4096
  end

  if Vagrant.has_plugin?("vagrant-vbguest")
    config.vbguest.auto_update = false
  end
  config.vm.provision "shell", privileged: false, inline: <<-SHELL
    bash -eu /vagrant/install.sh 192.168.56.10 enp0s8 192.168.56.96/28
    cilium connectivity test
  SHELL
end
