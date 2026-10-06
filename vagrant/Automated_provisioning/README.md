# Automated deployment of the project locally using Vagrant

This section provides a step-by-step guide to automatically deploy the project locally using Vagrant. By following these instructions, you will be able to set up a local development environment that mirrors the production environment, allowing for efficient testing and development.

To facilitate it we have provided a Vagrantfile that defines the baseline configuration of the virtual machine, including the operating system, network settings, and shared folders.

Additionally, we have included provisioning command lines to be executed by you, the curious user, during the provisioning process that automate the installation of necessary software and dependencies.

## Pre-requisites

- Oracle VirtualBox
- Git bash or equivalent terminal
- Vagrant
- Vagrant plugins: 
  - vagrant-vbguest:
    - vagrant-vbguest is a Vagrant plugin that automatically installs the host's VirtualBox Guest Additions on the guest system.
    - This ensures that the guest system has the necessary drivers and tools to work seamlessly with the host system, improving performance and enabling features like shared folders and clipboard sharing.
  - vagrant-hostmanager:
    - It automatically updates the /etc/hosts file with the hostnames and IP addresses of all the virtual machines that are brought up with Vagrant.
    - It allows both the virtual machines and your computer to communicate with each other using easy-to-remember names (for example, db01, app01, web01), instead of having to use IP addresses.

## Steps to automatically deploy the project locally using Vagrant

1. Clone the repository to your local machine using Git bash or equivalent terminal:
   ```bash
   git clone https://github.com/A00AB772/devops-exercise-from-local-to-cloud
   ```
   
2. Navigate to the project directory:
   ```bash
   cd devops-exercise-from-local-to-cloud/vagrant/Automated_provisioning
   ```
   
You can see there the [Automatically Provisioned Vagrantfile](vagrant/Automated_provisioning/Vagrantfile) file, which defines the default configuration of the virtual machines over which we will be running the installation scripts after they are successfully spinned up.

3. Start the Vagrant environment:
   ```bash
    user@DESKTOP-SCNMK3I MINGW64 ~/Documents/devops-exercise-from-local-to-cloud/vagrant/Automated_provisioning
    $ vagrant up
    Bringing machine 'db01' up with 'virtualbox' provider...
    Bringing machine 'mc01' up with 'virtualbox' provider...
    Bringing machine 'rmq01' up with 'virtualbox' provider...
    Bringing machine 'app01' up with 'virtualbox' provider...
    Bringing machine 'web01' up with 'virtualbox' provider...
    ==> db01: Importing base box 'generic/centos9s'...
    ==> db01: Matching MAC address for NAT networking...
    ...
      
   ```
   
after a while, you will see the output of the provisioning commands being executed on each VM and the installation of the necessary software and dependencies being completed.

Also, you will be able to access the application via the browser at http://web01 or http://<your-vm-ip>.

![access_through_web01_nginx_proxy](images/access_through_web01_nginx_proxy.png)

After you test it you can destroy the Vagrant environment to free up system resources:


## Conclusion

Overall experience is that, the automated provisioning of the project has been a great success, allowing for a quick and efficient setup of the local development environment. The use of Vagrant and the provided provisioning scripts has streamlined the process, reducing the time and effort required to set up the environment.

This is the baseline for next step, which is to deploy the project in the cloud, which will allow for more efficient testing and development in a production-like environment.
