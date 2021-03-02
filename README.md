# Debezium Vagrant Box for Oracle DB

This is a Vagrant configuration for setting up a virtual machine based on Fedora 30, containing
an Oracle DB instance for testing.
Note that you'll need to download the Oracle installation yourself in order for preparing the testing environment.

[Ansible](http://docs.ansible.com/ansible/latest/index.html) is used for provisioning the VM, see _playbook.yml_ for the complete set-up.

<a href="#compatibility"></a>
## Oracle Compatibility

* Oracle 11 XE
  * Oracle XStream is not supported
  * Can only be used with Debezium Oracle connector using LogMiner adapter.


* Oracle 18 XE
  * Debezium Oracle connector not compatible regardless of adapter.
    * Flashback queries not supported (required for snapshotting data)
    * Supplemental logging not supported (required for streaming changes)
  
## Preparations

Make sure to have the following installed:

* [VirtualBox](https://www.virtualbox.org/)
* [Vagrant](https://www.vagrantup.com/)

## Installation

Clone this repository:

```
git clone https://github.com/debezium/oracle-vagrant-box.git
cd oracle-vagrant-box
mkdir -p data
cp setup-*.sh data/
```

Download the Oracle [installation file](http://www.oracle.com/technetwork/database/enterprise-edition/downloads/index.html) and provide it within the previously created _data_ directory.

## Starting the VM

Change into the project directory, and bootstrap the VM:

```
vagrant up
```

_If you get the error `Vagrant was unable to mount VirtualBox shared folders. This is usually because the filesystem "vboxsf" is not available.` then run :_

```
vagrant plugin install vagrant-vbguest
vagrant reload
vagrant provision
```

Once the VM has completed the boot sequence and has been provisioned, SSH into the VM:

```
vagrant ssh
```


## Setting up Oracle DB

<a href="#setup-environment-for-image"></a>
### Setup environment

#### Get the Oracle docker-images repository

The Oracle `docker-images` repository must be cloned from GitHub.
While this repository contains various Docker configurations for many Oracle products,
we're only interested in those for the `OracleDatabase`.

```
git clone https://github.com/oracle/docker-images.git
```

Navigate to the Oracle database single instance directory, shown below:

```
cd docker-images/OracleDatabase/SingleInstance/dockerfiles
```

#### Permissions

For all Oracle installations _except Oracle 11_, the image specifies a volume in which all Oracle database files are kept on the host machine.
This location needs to be created if it doesn't exist and provided the necessary permissions:

```
sudo mkdir -p /home/vagrant/oradata/recovery_area
sudo chgrp 54321 /home/vagrant/oradata
sudo chown 54321 /home/vagrant/oradata
sudo chgrp 54321 /home/vagrant/oradata/recovery_area
sudo chown 54321 /home/vagrant/oradata/recovery_area
```

<a href="#cdb-non-cdb"></a>
#### CDB or non-CDB

Beginning with Oracle 12, the database is installed using CDB-mode by default, enabling multi-tenancy support.
If you wish to test using CDB mode, please skip this section.
If you wish to test using non-CDB mode, only Oracle 12/19 (EE versions) provide a way to toggle non-CDB.

Open the Database Configuration Assistant (DBCA) configuration template file, as shown below.
This file controls precisely how Oracle will be installed.

```
vi <oracle-version>/dbca.rsp.tmpl
```

Locate the following two configuration options in the file, change their values respectively and save:

```
createAsContainerDatabase=false
numberOfPDBs=0
```

Now when the database performs its installation procedures in the [Running the Container](#running-the-container) section,
the database will be installed using non-CDB mode without pluggable databases.

### Build the image

Before the Oracle database image can be built, the installation files that were downloaded from Oracle OTN must be staged.
The following shows how to stage Oracle 11, 12, 18, and 19 as well as how to initiate the image build.
If the file downloaded from Oracle OTN is named differently than indicated here, 
the file must be renamed respectively; otherwise Docker will fail to locate the installation files.

#### Oracle 11 XE
```
cp /vagrant_data/oracle-xe-11.2.0-1.0.x86_64.rpm.zip 11.2.0.2
./buildContainerImage.sh -v 11.2.0.2 -i -x
```

#### Oracle 12 EE
```
cp /vagrant_data/linuxx64_12201_database.zip 12.2.0.1
./buildContainerImage.sh -v 12.2.0.1 -i -e
```

#### Oracle 19 EE
```
cp /vagrant_data/LINUX.X64_193000_db_home.zip 19.3.0
./buildContainerImage.sh -v 19.3.0 -i -e
```

<a href="#running-the-container"></a>
### Running the container

Depending on the Oracle version being used, certain docker switches may/may not be needed.
The following shows how to start each of the Oracle database versions using `docker run`.
Please wait until you see a message that the `DATABASE IS READY` in the logs.

NOTE: If you have changed the DBCA configuration script to install the database in non-CDB mode, 
you may see a message that the database failed to start.
This is normal as the failure is due to a bug in the Oracle start-up scripts that perform a PDB operation in non-CDB mode.

#### Oracle 11
```
docker run --name dbz_oracle --shm-size=1g -p 1521:1521 -e ORACLE_PWD=top_secret oracle/database:11.2.0.2-xe
```

#### Oracle 12
```
docker run --name dbz_oracle -p 1521:1521 -e ORACLE_PWD=top_secret -v /home/vagrant/oradata/:/opt/oracle/oradata oracle/database:12.2.0.1-ee
```

#### Oracle 19
```
docker run --name dbz_oracle -p 1521:1521 -e ORACLE_PWD=top_secret -v /home/vagrant/oradata/:/opt/oracle/oradata oracle/database:19.3.0-ee
```

### Database configuration

As mentioned in the [Setup environment for image](#setup-environment-for-image), Oracle defaults to multi-tenancy installations since Oracle 12.
For Oracle EE installations, the container will be named `ORCLCDB` while the pluggable database is named `ORCLPDB1`.
For Oracle 11, the database does not have multi-tenancy support, so the database is simply named `XE`.

At this point, the database has been installed but one additional step is required,
and that is to configure the database with the necessary features, users and permissions, etc that enable Debezium to capture change events.

The database can be configured to use:

* [XStreams](#xstreams)
* [LogMiner](#logminer)

<a name="xstreams"></a>
#### XStreams database configuration

An automated script has been provided in order to configure the database with XStreams support.
If you started the Docker image without daemon mode, you may need to open a new `vagrant ssh` shell.
In the vagrant box, run the following based on your Oracle version used:

##### Oracle 12 and 19 (CDB)
```
cat /vagrant_data/setup-xstream.sh | docker exec -i dbz_oracle bash
```

##### Oracle 12 and 19 (non-CDB)
```
cat /vagrant_data/setup-xstream-noncdb.sh | docker exec -i dbz_oracle bash
```

When the script execution has completed, the database is fully configured and ready to send change events to Debezium.

<a name="logminer"></a>
#### LogMiner database configuration

An automated script has been provided in order to configure the database with LogMiner support.
If you started the Docker image without daemon mode, you may need to open a new `vagrant ssh` shell.
In the vagrant box, run the following based on your Oracle version used: 

##### Oracle 11 XE
```
cat /vagrant_data/setup-logminer-11.sh | docker exec -i --user=oracle dbz_oracle bash
```

##### Oracle 12 and 19 (CDB)
```
cat /vagrant_data/setup-logminer.sh | docker exec -i dbz_oracle bash
```

##### Oracle 12 and 19 (non-CDB)
```
cat /vagrant_data/setup-logminer-noncdb.sh | docker exec -i dbz_oracle bash
```

When the script execution has completed, the database is fully configured and ready to send change events to Debezium.

## FAQ

### Why is there no Oracle 11 XE for XStreams or no reference to Oracle 18 XE?

See the [Compatibility](#compatibility) section for details.

### Why is Oracle performing log switches too frequently? 

This is often due to the fact that the redo logs are configured with sizes too small, or the number of groups is too few.
In Oracle XE installations, this will happen because the default configuration uses redo logs with a size of `50MB`.
Please see <a href="REDOLOG_SETUP.md">REDOLOG_SETUP.md</a> for instructions on how to adjust the redo log setup.

### After restarting `dbz_oracle` with XStreams, container reports insufficient privileges.

This happens because the Oracle Copy Process (CP) for XStreams fails to start when the container has been restarted.  
The easiest solution to resolve this problem is to remove the Outbound Server and recreate it.

The following assumes an Oracle database named `ORCLCDB`.
Please adjust the `ORACLE_SID` value based on your environment's setup and configuration.

To drop the outbound server:

```
vagrant ssh
docker exec -it -e ORACLE_SID=ORCLCDB dbz_oracle bash
sqlplus /nolog <<- EOF
connect sys/top_secret;
exec dbms_xstream_adm.drop_outbound('dbzxout');
```

To re-create the outbound server, open the setup script for your Oracle environment and scroll to the bottom.
There are 2 `sqlplus` commands listed where the first creates the outbound while the second alters it.
Simply cut-n-paste those two commands into the terminal of `dbz_oracle` to execute them.

Now XStreams should work as it did previously prior to the container shutdown.

## License

This project is licensed under the Apache License version 2.0.
