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
cd oracle-vagrant-box
mkdir -p data
cp setup.sh data/
```

Download the Oracle [installation file](http://www.oracle.com/technetwork/database/enterprise-edition/downloads/index.html) and provide it within the previously created _data_ directory.

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

Now SSH into the VM: 

```
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
sudo mkdir -p /home/vagrant/oradata/recovery_area
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
The database can be configured to use [xstreams](#xstreams) or [log miner](#logminer).
Please see each section for details on configuration steps.

<a name="xstreams"></a>
### XStreams database configuration

You can configure it in automated way using provided installation script or you can follow the [manual steps](#xstreams-manual) to understand the necessary pre-conditions.

To configure the database automatically run:

```
cat /vagrant_data/setup.sh | docker exec -i dbz_oracle bash
```
When the script execution is completed the database is fully configured and prepared to send change events into Debezium.
The following chapter explains steps that are executed as part of the configuration process.

<a name ="xstreams-manual"></a>
#### XStreams Manual steps

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
GRANT FLASHBACK ANY TABLE TO c##xstrm CONTAINER=ALL;

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

<a name="logminer"></a>
### Log Miner database configuration

You can configure the database to use Log Miner in an automated way using the provided installation script.
However prior to running the script, there are some manual steps you must perform.

First you need to determine the current redo log state in the database:

```
$ docker exec -ti -e ORACLE_SID=ORCLCDB dbz_oracle sqlplus /nolog

SQL> CONNECT sys/top_secret AS SYSDBA

SQL> select group#, bytes/1024/1024, status from v$log order by 1;

    GROUP# BYTES/1024/1024 STATUS
---------- --------------- ----------------
	 1	       200 INACTIVE
	 2	       200 CURRENT
	 3	       200 UNUSED

SQL> select group#, member from v$logfile order by 1, 2;

GROUP# MEMBER
------ ------------------------------------------------------------
	 1 /opt/oracle/oradata/ORCLCDB/redo01.log
	 2 /opt/oracle/oradata/ORCLCDB/redo02.log
	 3 /opt/oracle/oradata/ORCLCDB/redo03.log

SQL> select group#, bytes/1024/1024, status from v$log order by 1;

    GROUP# BYTES/1024/1024 STATUS
---------- --------------- ----------------
	 1	       200 INACTIVE
	 2	       200 CURRENT
	 3	       200 INACTIVE
```

Clear and drop redo log files for logfile group 1.
In order to add multiple log files, the group's logfile descriptor must be dropped.
The default size is `200M`, we will continue to use this for now.

```
SQL> alter database clear logfile group 1;

Database altered.

SQL> alter database drop logfile group 1;

Database altered.

SQL> alter database add logfile group 1 ('/opt/oracle/oradata/ORCLCDB/redo01.log', '/opt/oracle/oradata/ORCLCDB/redo01a.log') size 200M reuse;

Database altered.
```

Clear and drop redo log files for logfile group 3.
Just like group 1, the logfile descriptor must be dropped before multiple log files can be added.
The default size is `200M`, we will continue to use this for now.

```
SQL> alter database clear logfile group 3;

Database altered.

SQL> alter database drop logfile group 3;

Database altered.

SQL> alter database add logfile group 3 ('/opt/oracle/oradata/ORCLCDB/redo03.log', '/opt/oracle/oradata/ORCLCDB/redo03a.log') size 200M reuse;

Database altered.
```


In order to modify logfile group 2, a log switch must be performed.

```
SQL> alter system switch logfile;

System altered.
```

Now continue to query the database until logfile group 2 is `INACTIVE`.
This can take a while until the database transitions from `ACTIVE` to `INACTIVE`.

Once it has moved to `INACTIVE`, clear and drop redo log files for logfile group 2.
Just like group 1, the logfile descriptor must be dropped before multiple log files can be added.
The default size is `200M`, we will continue to use this for now.

```
SQL> alter database clear logfile group 2;

Database altered.

SQL> alter database drop logfile group 2;

Database altered.

SQL> alter database add logfile group 2 ('/opt/oracle/oradata/ORCLCDB/redo02.log', '/opt/oracle/oradata/ORCLCDB/redo02a.log') size 200M reuse;

Database altered.
```

At this point, the following should be the database state:

```
SQL> select group#, bytes/1024/1024, status from v$log order by 1;

    GROUP# BYTES/1024/1024 STATUS
---------- --------------- ----------------
	 1	       200 CURRENT
	 2	       200 UNUSED
	 3	       200 UNUSED

SQL> select group#, member from v$logfile order by 1, 2;

GROUP# MEMBER
------ ------------------------------------------------------------
	 1 /opt/oracle/oradata/ORCLCDB/redo01.log
	 1 /opt/oracle/oradata/ORCLCDB/redo01a.log
	 2 /opt/oracle/oradata/ORCLCDB/redo02.log
	 
GROUP# MEMBER
------ ------------------------------------------------------------
	 2 /opt/oracle/oradata/ORCLCDB/redo02a.log
	 3 /opt/oracle/oradata/ORCLCDB/redo03.log
	 3 /opt/oracle/oradata/ORCLCDB/redo03a.log

6 rows selected.
```

At this point the redo logs have 3 redo groups, but we ideally want to use `5` or `7`.
For testing purposes we can rely on `5` for our use case.
In order to add two additional redo groups the database needs to be altered:

```
SQL> alter database add logfile group 4 ('/opt/oracle/oradata/ORCLCDB/redo04.log', '/opt/oracle/oradata/ORCLCDB/redo04a.log') size 200M reuse;

Database altered.

SQL> alter database add logfile group 5 ('/opt/oracle/oradata/ORCLCDB/redo05.log', '/opt/oracle/oradata/ORCLCDB/redo05a.log') size 200M reuse;

Database altered.
```

At this point the Oracle redo logs queries should give you similar output to the following:

```
SQL> select group#, bytes/1024/1024, status from v$log order by 1;

    GROUP# BYTES/1024/1024 STATUS
---------- --------------- ----------------
	 1	       200 CURRENT
	 2	       200 UNUSED
	 3	       200 UNUSED
	 4         200 UNUSED
	 5         200 UNUSED

SQL> select group#, member from v$logfile order by 1, 2;

GROUP# MEMBER
------ ------------------------------------------------------------
	 1 /opt/oracle/oradata/ORCLCDB/redo01.log
	 1 /opt/oracle/oradata/ORCLCDB/redo01a.log
	 2 /opt/oracle/oradata/ORCLCDB/redo02.log
	 
GROUP# MEMBER
------ ------------------------------------------------------------
	 2 /opt/oracle/oradata/ORCLCDB/redo02a.log
	 3 /opt/oracle/oradata/ORCLCDB/redo03.log
	 3 /opt/oracle/oradata/ORCLCDB/redo03a.log

GROUP# MEMBER
------ ------------------------------------------------------------
	 4 /opt/oracle/oradata/ORCLCDB/redo04.log
	 4 /opt/oracle/oradata/ORCLCDB/redo04a.log
	 5 /opt/oracle/oradata/ORCLCDB/redo05.log

GROUP# MEMBER
------ ------------------------------------------------------------
	 5 /opt/oracle/oradata/ORCLCDB/redo05a.log
	 	 
10 rows selected.
```

At this point the configuration script for Log Miner can be used to setup the rest of the database.

```
cat /vagrant_data/setup-logminer.sh | docker exec -i dbz_oracle bash
```

When the script execution is completed the database is fully configured and prepared to send change events into Debezium.

## License

This project is licensed under the Apache License version 2.0.
