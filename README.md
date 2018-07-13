# Debezium Vagrant Box for Oracle DB

This is a Vagrant configuration for setting up a virtual machine based on Fedora 27, containing
an Oracle DB instance for testing.
Note that you'll need to download the Oracle installation yourself in order for preparing the testing environment.

[Ansible](http://docs.ansible.com/ansible/latest/index.html) is used for provisioning the VM, see _playbook.yml_ for the complete set-up.

## Preparations

Make sure to have the following installed:

* [VirtualBox](https://www.virtualbox.org/)
* [Vagrant](https://www.vagrantup.com/)

## Installation

Clone this repository:

```
git clone https://github.com/debezium/oracle-vagrant-box.git
```

Download the Oracle [installation file](http://www.oracle.com/technetwork/database/enterprise-edition/downloads/index.html) and provide it within the _data_ directory.

Change into the project directory, bootstrap the VM and SSH into it:

```
cd oracle-vagrant-box
vagrant up
vagrant ssh
```

## Setting up Oracle DB

Clone the Oracle Docker images GitHub repository:

```
git clone https://github.com/oracle/docker-images.git
```

Build the Docker image with the database:

```
cd docker-images/OracleDatabase/SingleInstance/dockerfiles
cp /vagrant_data/linuxx64_12201_database.zip 12.2.0.1
./buildDockerImage.sh -v 12.2.0.1 -i -e
```

Create a data directory and run the container:

```
mkdir -p /home/vagrant/oradata/recovery_area
sudo chgrp 54321 /home/vagrant/oradata
sudo chown 54321 /home/vagrant/oradata
sudo chgrp 54321 /home/vagrant/oradata/recovery_area
sudo chown 54321 /home/vagrant/oradata/recovery_area
```

Run the container

```
docker run --name dbz_oracle -p 1521:1521 -e ORACLE_PWD=top_secret -v /home/vagrant/oradata/:/opt/oracle/oradata oracle/database:12.2.0.1-ee
```
and wait for the database to start.

### Database configuration

Note: as foreseen by the Oracle Docker image, the following assumes that the multi-tenancy model is used,
with the container database being named `ORCLCDB` and a pluggable database being named `ORCLPDB1`.

The last step to do is to configure the started database.
You can configure it in automated way using provided installation script or you can follow the manual steps to understand the necessary pre-conditions.

To configure the database automatically run:

```
cat setup.sh | docker exec -i dbz_oracle bash
```
When the script execution is completed the database is fully configured and prepared to send change events into Debezium.
The following chapter explains steps that are executed as part of the configuration process.

#### Manual steps

Set archive log mode and enable GG replication:

```
docker exec -ti -e ORACLE_SID=ORCLCDB dbz_oracle sqlplus /nolog

CONNECT sys/top_secret AS SYSDBA
alter system set db_recovery_file_dest_size = 5G;
alter system set db_recovery_file_dest = '/opt/oracle/oradata/recovery_area' scope=spfile;
alter system set enable_goldengate_replication=true;
shutdown immediate
startup mount
alter database archivelog;
alter database open;
-- Should show "Database log mode: Archive Mode"
archive log list

exit;
```

Create XStream admin user in the container database
(used per Oracle's recommendation for administering XStream):

```
docker exec -ti dbz_oracle sqlplus sys/top_secret@//localhost:1521/ORCLCDB as sysdba
CREATE TABLESPACE xstream_adm_tbs DATAFILE '/opt/oracle/oradata/ORCLCDB/xstream_adm_tbs.dbf'
  SIZE 25M REUSE AUTOEXTEND ON MAXSIZE UNLIMITED;
exit;
```

```
docker exec -ti dbz_oracle sqlplus sys/top_secret@//localhost:1521/ORCLPDB1 as sysdba
CREATE TABLESPACE xstream_adm_tbs DATAFILE '/opt/oracle/oradata/ORCLCDB/ORCLPDB1/xstream_adm_tbs.dbf'
  SIZE 25M REUSE AUTOEXTEND ON MAXSIZE UNLIMITED;
exit;
```

```
docker exec -ti dbz_oracle sqlplus sys/top_secret@//localhost:1521/ORCLCDB as sysdba

CREATE USER c##xstrmadmin IDENTIFIED BY xsa
  DEFAULT TABLESPACE xstream_adm_tbs
  QUOTA UNLIMITED ON xstream_adm_tbs
  CONTAINER=ALL;

GRANT CREATE SESSION, SET CONTAINER TO c##xstrmadmin CONTAINER=ALL;

BEGIN
   DBMS_XSTREAM_AUTH.GRANT_ADMIN_PRIVILEGE(
      grantee                 => 'c##xstrmadmin',
      privilege_type          => 'CAPTURE',
      grant_select_privileges => TRUE,
      container               => 'ALL'
   );
END;
/

exit;
```

Create test user in the pluggable database (i.e. a regular user of the database):

```
docker exec -ti dbz_oracle sqlplus sys/top_secret@//localhost:1521/ORCLPDB1 as sysdba

CREATE USER debezium IDENTIFIED BY dbz;
GRANT CONNECT TO debezium;
GRANT CREATE SESSION TO debezium;
GRANT CREATE TABLE TO debezium;
GRANT CREATE SEQUENCE TO debezium;
ALTER USER debezium QUOTA 100M ON users;

exit;
```

Create XStream user (used by the Debezium connector to connect to the XStream outbound server):

```
docker exec -ti dbz_oracle sqlplus sys/top_secret@//localhost:1521/ORCLCDB as sysdba
CREATE TABLESPACE xstream_tbs DATAFILE '/opt/oracle/oradata/ORCLCDB/xstream_tbs.dbf'
  SIZE 25M REUSE AUTOEXTEND ON MAXSIZE UNLIMITED;
exit;
```

```
docker exec -ti dbz_oracle sqlplus sys/top_secret@//localhost:1521/ORCLPDB1 as sysdba
CREATE TABLESPACE xstream_tbs DATAFILE '/opt/oracle/oradata/ORCLCDB/ORCLPDB1/xstream_tbs.dbf'
  SIZE 25M REUSE AUTOEXTEND ON MAXSIZE UNLIMITED;
exit;
```

```
docker exec -ti dbz_oracle sqlplus sys/top_secret@//localhost:1521/ORCLCDB as sysdba

CREATE USER c##xstrm IDENTIFIED BY xs
  DEFAULT TABLESPACE xstream_tbs
  QUOTA UNLIMITED ON xstream_tbs
  CONTAINER=ALL;

GRANT CREATE SESSION TO c##xstrm CONTAINER=ALL;
GRANT SET CONTAINER TO c##xstrm CONTAINER=ALL;
GRANT SELECT ON V_$DATABASE to c##xstrm CONTAINER=ALL;

exit;
```

Create XStream Outbound server:

```
docker exec -ti dbz_oracle sqlplus c##xstrmadmin/xsa@//localhost:1521/ORCLCDB

DECLARE
  tables  DBMS_UTILITY.UNCL_ARRAY;
  schemas DBMS_UTILITY.UNCL_ARRAY;
BEGIN
    tables(1)  := NULL;
    schemas(1) := 'debezium';
  DBMS_XSTREAM_ADM.CREATE_OUTBOUND(
    server_name     =>  'dbzxout',
    table_names     =>  tables,
    schema_names    =>  schemas);
END;
/

exit;
```

Alter the XStream Outbound server to allow the `xstrm` user to connect to it:

```
docker exec -ti dbz_oracle sqlplus sys/top_secret@//localhost:1521/ORCLCDB as sysdba

BEGIN
  DBMS_XSTREAM_ADM.ALTER_OUTBOUND(
    server_name  => 'dbzxout',
    connect_user => 'c##xstrm');
END;
/

exit;
```

## License

This project is licensed under the Apache License version 2.0.
