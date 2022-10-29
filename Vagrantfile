Vagrant.configure("2") do |config|
  config.vm.box = "ubuntu/focal64"
  config.vm.box_version = "20221025.0.0"

  config.vm.network "private_network", ip: "192.168.56.210"

  config.vm.provider "virtualbox" do |vb|
    vb.cpus = 4
    vb.memory = 4096
  end

  if Vagrant.has_plugin?("vagrant-vbguest")
    config.vbguest.auto_update = false
  end
  config.vm.provision "shell", privileged: false, inline: <<-SHELL
    bash -eu /vagrant/install.sh 192.168.56.210
  SHELL
end
