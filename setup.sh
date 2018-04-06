#!/bin/sh

# Set archive log mode and enable GG replication
ORACLE_SID=ORCLCDB
export ORACLE_SID
sqlplus /nolog <<- EOF
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
EOF

# Create XStream admin user
sqlplus sys/top_secret@//localhost:1521/ORCLCDB as sysdba <<- EOF
	CREATE TABLESPACE xstream_tbs DATAFILE '/opt/oracle/oradata/ORCLCDB/xstream_tbs.dbf'
	  SIZE 25M REUSE AUTOEXTEND ON MAXSIZE UNLIMITED;
	exit;
EOF
sqlplus sys/top_secret@//localhost:1521/ORCLPDB1 as sysdba <<- EOF
	CREATE TABLESPACE xstream_tbs DATAFILE '/opt/oracle/oradata/ORCLCDB/ORCLPDB1/xstream_tbs.dbf'
	  SIZE 25M REUSE AUTOEXTEND ON MAXSIZE UNLIMITED;
	exit;
EOF
sqlplus sys/top_secret@//localhost:1521/ORCLCDB as sysdba <<- EOF
	CREATE USER c##xstrmadmin IDENTIFIED BY xsa
	  DEFAULT TABLESPACE xstream_tbs
	  QUOTA UNLIMITED ON xstream_tbs
	  CONTAINER=ALL;

	GRANT CREATE SESSION, SET CONTAINER TO c##xstrmadmin CONTAINER=ALL;
	GRANT DBA TO c##xstrmadmin;

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
EOF

# Create test user
sqlplus sys/top_secret@//localhost:1521/ORCLPDB1 as sysdba <<- EOF
	CREATE USER debezium IDENTIFIED BY dbz;
	GRANT CONNECT TO debezium;
	GRANT CREATE SESSION TO debezium;
	GRANT CREATE TABLE TO debezium;
	GRANT CREATE SEQUENCE TO debezium;
	ALTER USER debezium QUOTA 100M ON users;

	exit;
EOF

# Create XStream Outbound server
sqlplus c##xstrmadmin/xsa@//localhost:1521/ORCLCDB <<- EOF
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
EOF
