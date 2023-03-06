# gravedancer
This repository contains a powerful open-source script for backing-up, checking and storing **MariaDB** *backups*. This script is going to be redone as a microservice application.

### Table of contents
* [Fallback use of **MariaDB** **OpenStack** controllers. Description](#fallback-use-of-mariadb-openstack-controllers-description)
* [Prerequisites](#prerequisites)
* [Infrastructure preparation](#infrastructure-preparation)
* [Script preparation](#script-preparation)
* [The logic of the script](#the-logic-of-the-script)
  * [Description of the pre-collection and post-processing process](#description-of-the-pre-collection-and-post-processing-process-gold-lines)
  * [Description of the testing process after post-processing](#description-of-the-testing-process-after-post-processing-blue-line)
  * [Description of the backup process to the master server and post-processing](#description-of-the-process-of-sending-a-backup-to-the-master-server-and-post-processing-green-line)

## Fallback use of **MariaDB** **OpenStack** controllers. Description

The script is designed for effective logical *backup* of **MySQL 5+** and **MariaDB 10+** **database** with subsequent data consistency check according to numerous parameters, which will be described below. The script was developed taking into account the specifics of the **database** operation in a productive **OpenStack** environment, with the expectation that the configuration of the regions is +/- the same, which means the same type of data structure in the target product **database**.

The principle of operation is to take parallel *backups* from the required number of hosts, check performance, local consistency check, calculate statistical data, restore each *backup* on a specially prepared **database** server, followed by data integrity checks, after the checks are completed, send to the *backup* server based on the solution **Veritas NetBackup**, execution finalization and summary in the form of small statistics. The script includes storing hot *backups* for the required period of time on the executor server with adjustable auto-cleaning of obsolete copies using maximum **gzip** compression.

While the script is running, all the necessary working directories are created, directories for logging in the current date format, directories for storing hot *backups* in a similar format. Files are named according to the region designation + date up to seconds. At the time of writing the documentation on 29/03/2021, the script is written in **BASH**, which allows it to be used natively on **Linux** systems. In the future, it is planned to expand the functionality, add useful features and advanced alerts, as well as a convenient management interface.

## Prerequisites

### Infrastructure preparation:

1. Specially prepared server with **MySQL** || **MariaDB** is on board the version you use in production. It is possible to use for these purposes the executor server where the script is located and runs. It must be taken into account that depending on the number of *backups* being restored, the number of binary logs / logs on the server with the **database** for testing *backups* will increase, therefore, it is necessary to configure automatic log cleanup in accordance with the load, because. on the server with the test **database**, they have no value.
2. **MySQL** | **MariaDB** client of the same version as the **database**, installed on the executor host so that the script can make *backups* of the **database** and restore them on the test server.
3. A **gzip** package for compressing the collected dumps on the executor server and subsequent long-term storage.
4. One or more **database** as a target for dumping.
5. The reserve of free space on the server-executor and the test server with a **database** on board is *at least 1GB*. To be able to collect at least one dump.
6. Create a user in each target productive **database** with the name backupuser and the same password on all **database**/clusters with privileges to create a *backup* copy.
7. Create a **database** user named restoreuser on the test **database** server with rights to restore the **database** and execute SELECT queries to any **database** and table.
8. If you plan to use the script in conjunction with Veritas **NetBackup**, you must have a **NetBackup** Master Server && installed **NetBackup** client on the host where the script will be located. If not required, it is recommended to change the send by using scp.
9. **It is necessary to have a backupuser in the production db:**
```
MariaDB [(none)]> create user backupuser identified by '..............';
Query OK, 0 rows affected (0.014 sec)

MariaDB [(none)]> grant select on *.* to backupuser;
Query OK, 0 rows affected (0.014 sec)

MariaDB [(none)]> grant lock tables on *.* to backupuser;
Query OK, 0 rows affected (0.013 sec)

MariaDB [(none)]> grant reload on *.* to backupuser;
Query OK, 0 rows affected (0.013 sec)

MariaDB [(none)]> grant show view on *.* to backupuser;
Query OK, 0 rows affected (0.013 sec)

MariaDB [(none)]> grant replication client on *.* to backupuser;
Query OK, 0 rows affected (0.012 sec)

MariaDB [(none)]> 
```

## Script preparation

1. The working directory of the script must be located along the path `/root/maintenance`
2. In the *variable* section `#Backup Params` -> `#Production Params` for the `$VIP` array *variable*, at least one IP address of the target product base for dumping must be specified. 

> **ATTENTION!** The *variable* containing the addresses of the target hosts must contain the values in logical order with the `$REG` *variable*. For example, in the `$VIP` *variable* you have specified the following array `(“10.1.1.1” “10.1.1.2”)`, in the `$REG` *variable* you have specified an array `(“REG1” “REG2”)`. This is important for the correct formation of logs and avoid confusion.

3. In the `#Backup Params` -> `#Production Params` *variable* section, for the `$USER` *variable*, you must specify the username with the rights to dump **SQL** in the **database**.
4. In the `#Backup Params` -> `#Production Params` *variable* section for the `$PASSWD` *variable*, you must specify the backupuser password. Remember that it must be the same for each cluster or individual **database** that will participate in the *backup* process as targets.
5. In the `#Restore Params` -> `#Test restore server params variable` section, for the `$TESTDBVIP` *variable*, the IP address of the test **database** server for restoring and testing data integrity must be specified.
6. In the `#Restore Params` -> `#Test restore server params variable` section, for the `$TESTDBUSER` *variable*, the restoreuser username of the **database** server for restoring and testing data integrity must be specified.
7. In the `#Restore Params` -> `#Test restore server params variable` section, for the `$TESTDBPASSWD` *variable*, the password of the restoreuser user of the **database** server for restoring and testing data integrity must be specified.
8. Depending on the required consistency level, add to the `$TABLES` & `$DATABASES` arrays of the `#Check database params` section the tables and **database** for which you want to check.
9. In the `#Dump file params` section, set the `$REG` array *variable* to an intuitive name for what you are backing up. For example, in the standard edition of the script out of the box, the names of the **OpenStack** regions from which the dump is taken are indicated. 

> **ATTENTION!** The *variable* containing the logical names of the target hosts must contain the values in logical order with the `$VIP` *variable*. For example, in the `$VIP` *variable* you have specified the following array `(“10.1.1.1” “10.1.1.2”)`, in the `$REG` *variable* you have specified an array `(“REG1” “REG2”)`. This is important for the correct formation of logs and avoid confusion.

10. In the `#Log params` section, specify a boolean value for the `$MBHOST` *variable*, for example 'pd-09-backup-host', and for `$MBSIP` - the IP address of the *backup* server. Variables are used for logging and for substitution in the command to send a verified *backup* to the Master-Backup-Server.
11. In the `#Maintenance params` -> `#For directories older then NDAY` section, specify an integer value for the `$NDAY` *variable*, for example 3. This means that you want to clean up directories with logs and hot *backups* that are older than 3 days. The directories in which the files were located are also deleted.

## The logic of the script

![Gravedancer working schema](#https://drive.google.com/file/d/1-y52rBtRgy2QoWYx5RL7JMyx3d2AqzAl/view?usp=sharing)

### Description of the pre-collection and post-processing process **(gold lines)**.

1. A process is created and the **PID** of the script process is indicated in the working directory in the file, which is additionally reported in the log.
2. The executor connects to the target servers via port 3306 simultaneously (in parallel), the result of the process is fixed in a *variable* that is responsible for storing the exit code of the process. Performs dump collection, saving the following information in the storage directory and detailed logging to the log file: working directory, process **PID**, information about hosts and regions from which the dump is taken, the result of completing the dump collection.
3. The result of the execution is checked. If success, then we continue further, write down information about success for each region in the log. If not successful, take **mysqldump** output to log and error message. Checking working directories for outdated *backups*.
4. Collection of statistical information about (1) file size, (2) MD5 checksum, (3) control record at the beginning and end of the dump, (4) Finding the last *backup* file to calculate the difference in size, (5) full path to the file of the last *backup*, (6) the size of the last *backup* file, (7) a *variable* that stores the calculated difference in size between the last *backup* and the new one.
5. Information about (1) the size of the new *backup* file is written to the log (2) Verification that the dump is with a non-zero size. If the file is equal to zero, then (1) an error is written to the log with an explanation that the file is less than or equal to zero. The region with such a dump file is excluded from further checking in the loop body with a message about the region parameters (IP, name).
6. If this is the first dump for today, then a corresponding message is displayed in the log.
7. A message is written to the log about the difference in size with the calculation of the percentage compared to the last *backup* for today.
8. After successfully checking the new *backup*, the old one is compressed with **gzip**.
9. After the end of the check of statistical data, the check for the presence of control records in the dump, namely the version at the beginning of the dump, the final record at the end of the dump, begins. If the check is successful, the verification data gets into the log, and a checksum is assigned. Otherwise, the dump is deleted, and the region is excluded from further processing, which is reported in detail in the log.

### Description of the testing process after post-processing **(blue line)**

1. Each dump is checked sequentially, i.e. restored one dump - checked - move on to the next one.
2. The first dump from the array is restored, if the operation returned success, move on and write about it to the log. If not, delete the dump, exclude the region from further processing, write to the log.
3. Check that the **database** from the `${DATABASES[@]}` array exist in the *backup*. If yes, then we proceed to check the contents of the tables. If not, delete the dump, exclude the region from further processing, write to the log.
4. Check that the tables in the `${TABLES[@]}` array are not empty and the number of records is greater than zero. If so, we write to the log and proceed to send the *backup* to the *backup* master server using the **NetBackup** client installed on the executor. If this is not the case, then we delete the dump, exclude the region from further processing, and write to the log.

### Description of the process of sending a backup to the master server and post-processing **(green line)**

1. We send the file to the *backup* server using the **NetBackup** client.
2. If sending to the master server was successful, then check the time on the server, if the hour during which the script is running is 23, then write to the log that this is the last *backup* for today and compress it, completing the collection of dumps to this directory. If not, then the 'last' prefix is added to the new *backup* to simplify the search in the future at the next script initialization.
3. Check the directories for old files that match the number of days in the `$NDAY` *variable*. If something is found, then we delete it along with the directories, if we didn’t find anything, we write that we didn’t find anything.
4. Completing the execution, the final statistics is generated about which region a *backup* was created for, for which not. Delete process **PID**, exit with code 0.