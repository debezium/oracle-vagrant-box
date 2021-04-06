# Setting up Oracle Redo Logs

Oracle relies on Redo Logs to log all transactions performed against the database.
The primary purpose of these logs is to allow Oracle to recover changes made to the database in case of a failure.
The number of logs and their respective sizes depend greatly on frequency of changes and usage.
The steps taken in this document are to support the Debezium test suite requirements and are simply meant as a guide.

<a href="current"></a>
## Current State

Before making any changes, it's important to examine the current state of the database.
The following 2 SQL statements provide us precisely that:

```
SQL> select group#, bytes/1024/1024, status from v$log order by 1;

    GROUP# BYTES/1024/1024 STATUS
---------- --------------- ----------------
	 1	               200 INACTIVE
	 2	               200 CURRENT
	 3	               200 UNUSED

SQL> select group#, member from v$logfile order by 1, 2;

GROUP# MEMBER
------ ------------------------------------------------------------
	 1 /opt/oracle/oradata/ORCLCDB/redo01.log
	 2 /opt/oracle/oradata/ORCLCDB/redo02.log
	 3 /opt/oracle/oradata/ORCLCDB/redo03.log
```

The output above shows that there are `3` log groups, each group is configured with a size of `200MB`, each group has exactly 1 file assigned, and that currently only group `2` is being used.  
The status column can have `INACTIVE`, `UNUSED`, `CURRENT`, or `ACTIVE` values.  
The `CURRENT` status implies that is the log group currently being actively used by the database.
The `ACTIVE` status implies that the log group is currently required for failure recovery, i.e. it's needed for reading purposes, but the database isn't currently writing to it.

For Oracle EE installations, this is precisely what you should typically expect to see.
This configuration is adequate to run the Debezium test suite.

For Oracle XE installations, you will likely find that the logs are configured with a smaller size, typically `50MB`.
This size is too small for Debezium's test suite, particularly when using the default connector configurations, 
because the connector is going to write the data dictionary to the redo logs.  The data dictionary can consume quite
a bit of space in the logs and therefore they need to be tuned appropriately to support this operation but also to
provide a buffer for log switches.

In the future, we plan to see if there are ways we can support smaller log file sizes, 
but typically in any type of production deployment,
the logs are configured with sizes that are drastically larger than `200MB`; often in the gigabyte territory.

## Changing Redo Logs

The easiest way to change the redo log configuration is to _clear_, _drop_, and _re-add_ the group.
Please note, a group cannot be adjusted while it's currently in `ACTIVE` or `CURRENT` status.
The following steps assume the status values shown above, so adjust these accordingly.

### Group 1

Since logfile group 1 above is `INACTIVE`, we can proceed with changing its configuration.
Be mindful of the path used in the `add logfile` clause, this should be identical to the path used in [Current State](#current) section.

```
alter database clear logfile group 1;
alter database drop logfile group 1;
alter database add logfile group 1 ('/opt/oracle/oradata/ORCLCDB/redo01.log') size 200M reuse; 
```

### Group 3

Since logfile group 3 above is 'UNUSED', we can proceed with changing its configuration.
Be mindful of the path used in the `add logfile` clause, this should be identical to the path used in the [Current State](#current) section.

```
alter database clear logfile group 3;
alter database drop logfile group 3;
alter database add logfile group 3 ('/opt/oracle/oradata/ORCLCDB/redo03.log') size 200M reuse; 
```

### Group 2

Since logfile group 2 above is `CURRENT`, we cannot proceed with changing its configuration.
In order to be able to change it, we need to first ask Oracle to switch log files:

```
alter system switch logfile;
```

It will take the database a few minutes for group 2 to shift to `INACTIVE`.
You can check the status of the redo logs by running the very first SQL statement in the [Current State](#current) section.
Once the log group has shifted to `INACTIVE`, it's safe to proceed with changing its configuration.
Again, be mindful of the path used in the `add logfile` clause, this should be identical to the path used in the [Current State](#current) section.

```
alter database clear logfile group 2;
alter database drop logfile group 2;
alter database add logfile group 2 ('/opt/oracle/oradata/ORCLCDB/redo02.log') size 200M reuse; 
```

## Adding additional groups

You may find that you need to add additional redo log groups if you intend to reuse the same container for performance benchmarks or multiple test suite executions.
Adding additional redo logs simply allows Oracle to be more proficient in doing less swapping redo logs to archive logs and keeping the redo logs online longer.
In order to add additional redo groups, simply execute the following:

```
alter database add logfile group <group#> ('<path-to-logfile-to-add') size 200M reuse;
```

The `<group#>` should be changed to the next logical group number based on your setup.
If you have 3 redo log groups, you would first add group `4` and so forth.
The `<path-to-logfile-to-add>` should be assigned a path like that is used in the prior sections, adhering to the path used by other redo log files.

## Multiplexing logs

While it's unnecessary for our purposes of testing, Oracle does provide support for redo log multiplexing.
This allows the database to store identical copies of a redo log, often in separate locations to guard against recovery failure.
Even if the copies are on the same disk, multiple copies can guard against I/O failures, file corruption, and so on.

To use redo log multiplexing support, the `add logfile` SQL command should specify more than one logfile.
As an example, the following shows how we could change redo log group 1 to support multiple / multiplexed log files:

```
alter database add logfile group 1 ('/opt/oracle/oradata/ORCLCDB/redo01a.log', '/opt/oracle/oradata/ORCLCDB/redo01b.log') size 200M reuse;
```

