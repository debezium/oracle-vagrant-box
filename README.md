# Debezium Vagrant Box for Oracle DB

This is a Vagrant configuration for setting up a virtual machine based on Fedora 26, containing
an Oracle DB instance for testing.
Note that you'll need to download the Oracle installation yourself in order for preparing the testing environment.

The following tools are installed:

* Java 8 and Java 9
* Maven
* git
* Docker

Ansible is used for provisioning the VM, see _playbook.yml_ for the complete set-up.

## Installation

Clone this repository:

    git clone https://github.com/debezium/oracle-vagrant-box.git

Download the Oracle installation file and provide it within the _data_ directory.

Change into the project directory, bootstrap the VM and SSH into it:

    cd oracle-vagrant-box
    vagrant up
    vagrant ssh

## Setting up Oracle DB

TODO

## License

This project is licensed under the Apache License version 2.0.
