#!/bin/bash

################################## INFORMATION ##################################
# This script was written for the purpose of backing up the MariaDB database.   #
# The script backs up, checks the integrity of the database content.            #
# Once uploaded, the previous dump file is compressed with gzip.                #
# The solution has been tested for:                                             #
# 1) DB - mysql Ver 15.1 Distrib 10.3.24-MariaDB, for debian-linux-gnu (x86_64) #
# 2) DUMP - mysqldump  Ver 10.19 Distrib 10.6.0-MariaDB, for Linux (x86_64)     #
# 3) CLIENT - mysql  Ver 15.1 Distrib 10.6.0-MariaDB, for Linux (x86_64)        #
# Creator: Roman Ponkrashov | e-mail: roponkrashov@headstack.ru                 #
#################################################################################

#Backup params
#Production server params
VIP=("10.1.1.1" "10.2.2.2" "etc")
USER=backupusername
PASSWD=backupuserpass

#Restore params
#Test restore server params
TESTDBVIP=127.0.0.1
TESTDBUSER=restoreusername
TESTDBPASSWD=restoreuserpass

#Check database params
TABLES=("cinder.volume_admin_metadata" "glance.images" "keystone.project" "neutron.networks" "nova.migrations" "nova_api.aggregate_hosts" "placement.projects")
DATABASES=("cinder.volume_admin_metadata" "glance.images" "heat.event" "keystone.project" "neutron.networks" "nova.migrations" "nova_api.aggregate_hosts" "nova_cell0.agent_builds" "placement.projects" "rally.verifications")

#Dump file params
DIRDATE=$(date +%Y%m%d)
FILEDATE=$(date +%Y%m%d_%H%M%S)
REG=("srv-msrv-001" "srv-msrv-002" "etc")
LASTHOUR=$(date +%H)
DIR=/var/mdb_backup/dump

#Log params
LOGDIR=/var/mdb_backup/log
MBSHOST=netbackup_master_server
MBSIP=10.1.1.4

#Maintenance params
#Path for PID file
PFPID=/root/maintenance
#For directories older then NDAY
NDAY=1
WORKDIR=/var/mdb_backup
WHEREOLD=$(find $WORKDIR/* -type f -mtime +$NDAY)

#Create temporalilly PID file
echo $$>$PFPID/backup_mdb-$FILEDATE.pid
_PID=$(cat $PFPID/backup_mdb-$FILEDATE.pid 2>/dev/null)

#Make work dirs
if ! [ -d "$DIR/$DIRDATE/" -a -d "$LOGDIR/$DIRDATE/" ]; then
  mkdir -p $DIR/$DIRDATE
  mkdir -p $LOGDIR/$DIRDATE
  echo -e "\n$(date +%a\ %F\ %T\ %Z) [NOTICE] - Process script is started on host $(hostname) in a directory $PFPID with PID - $_PID. PID file is - $PFPID/backup_mdb-$FILEDATE.pid" >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log
  echo -e "$(date +%a\ %F\ %T\ %Z) [NOTICE] - Working directories not exist. Created. Current log dir - $LOGDIR/$DIRDATE Current SQL dump dir - $DIR/$DIRDATE" >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log
else
  echo -e "\n$(date +%a\ %F\ %T\ %Z) [NOTICE] - Process script is started on host $(hostname) in a directory $PFPID with PID - $_PID. PID file is - $PFPID/backup_mdb-$FILEDATE.pid" >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log
  echo -e "$(date +%a\ %F\ %T\ %Z) [NOTICE] - Working directories exist. Current log dir - $LOGDIR/$DIRDATE Current SQL dump dir - $DIR/$DIRDATE" >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log
fi

#Start database sql dump in background with collecting PID background processes
for (( bcount=0; bcount < 18; bcount++ )); do
  echo -e "$(date +%a\ %F\ %T\ %Z) [NOTICE] - Start creating SQL dump from host with IP - ${VIP[$bcount]} at the ${REG[$bcount]} region.." >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log
  mysqldump --host=${VIP[$bcount]} --user=$USER --password=$PASSWD -x -A > $DIR/$DIRDATE/mdb_bkp_${REG[$bcount]}-$FILEDATE.sql &
  PIDS+=($!)
done

#Wait for all processes to finish, and store each process's exit code into array STATUS[].
for pid in "${PIDS[@]}"; do
  wait ${pid}
  STATUS+=($?)
done

#Working with collected dumps
for (( bcount=0; bcount < 18; bcount++ )); do

    #Checking the validity of the completion of the operation
    if [ "${STATUS[$bcount]}" -eq 0 ]
    then
      echo -e "$(date +%a\ %F\ %T\ %Z) [NOTICE] - Database dump mdb_bkp_${REG[$bcount]}-$FILEDATE.sql collection operation completed successfully. Continue.." >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log
      
      #Dump checking params
      FILESIZEMIB=$(du -shm $DIR/$DIRDATE/mdb_bkp_${REG[$bcount]}-$FILEDATE.sql | awk '{ print $1 }')
      MD5SUM=$(md5sum -b $DIR/$DIRDATE/mdb_bkp_${REG[$bcount]}-$FILEDATE.sql | awk '{ print $1 }')
      STARTDUMP=$(cat $DIR/$DIRDATE/mdb_bkp_${REG[$bcount]}-$FILEDATE.sql | grep ^'-- MariaDB' | awk '{ print $2 }')
      ENDDUMP=$(cat $DIR/$DIRDATE/mdb_bkp_${REG[$bcount]}-$FILEDATE.sql | grep ^'-- Dump completed' | awk '{ print $3 }')
      LASTBACKUPFILE=$(find $DIR/$DIRDATE/ -type f -name "last_mdb_bkp_${REG[$bcount]}*" | sed 's/^\/.*\(mdb_bkp.*\)/\1/' 2>/dev/null)
      LASTBACKUPFILEFULLPATH=$(find $DIR/$DIRDATE/ -type f -name "last_mdb_bkp_${REG[$bcount]}*" 2>/dev/null)
      LASTBACKUPSIZE=$(find $DIR/$DIRDATE/ -type f -name "last_mdb_bkp_${REG[$bcount]}*" | xargs ls -sh | awk '{ print $1 }' | sed 's/^\([0-9]*\).*/\1/' 2>/dev/null)
      DIFFER=$(awk -v F1=$FILESIZEMIB -v F2=$LASTBACKUPSIZE 'BEGIN {print (F1/F2)*100-100}' 2>/dev/null | sed 's/^\([0-9].*\)/\1%/' 2>/dev/null)

      #Check dump size
      echo -e "$(date +%a\ %F\ %T\ %Z) [NOTICE] - Checking that the dump file mdb_bkp_${REG[$bcount]}-$FILEDATE.sql is greater than zero.." >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log
      if [ "$FILESIZEMIB" -gt 0 ]
      then
        echo -e "$(date +%a\ %F\ %T\ %Z) [NOTICE] - The size of the database dump file mdb_bkp_${REG[$bcount]}-$FILEDATE.sql is $FILESIZEMIB MiB. Continue.." >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log
      else
        echo -e "$(date +%a\ %F\ %T\ %Z) [ERROR] - The dump file is at most zero." >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log
        rm -f $DIR/$DIRDATE/mdb_bkp_${REG[$bcount]}-$FILEDATE.sql
        echo -e "$(date +%a\ %F\ %T\ %Z) [WARNING] - The region ${REG[$bcount]} with IP ${VIP[$bcount]} dump file is deleted!" >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log
        echo -e "$(date +%a\ %F\ %T\ %Z) [WARNING] - Region ${REG[$bcount]} is excluded from further processing!" >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log
        unset "VIP[$bcount]" && unset "REG[$bcount]"
        continue
      fi

      #Create stat about dump file new and old if exist
      if ! [ -f "$LASTBACKUPFILEFULLPATH" ]; then
        echo -e "$(date +%a\ %F\ %T\ %Z) [NOTICE] - The new database dump file has no predecessor. Probably because this is the first backup for today. No comparison will be made. Continue.." >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log
        echo -e "$(date +%a\ %F\ %T\ %Z) [NOTICE] - The size checking of the new database dump file $DIR/$DIRDATE/mdb_bkp_${REG[$bcount]}-$FILEDATE.sql has been completed successfully." >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log
      else
        echo -e "$(date +%a\ %F\ %T\ %Z) [NOTICE] - The size of the last created database dump file $LASTBACKUPFILE is $LASTBACKUPSIZE MiB." >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log
        echo -e "$(date +%a\ %F\ %T\ %Z) [NOTICE] - The new dump file mdb_bkp_${REG[$bcount]}-$FILEDATE.sql is $DIFFER more or less than the last dump file $LASTBACKUPFILE." >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log
        echo -e "$(date +%a\ %F\ %T\ %Z) [NOTICE] - The size checking of the new database dump file mdb_bkp_${REG[$bcount]}-$FILEDATE.sql has been completed successfully." >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log
        echo -e "$(date +%a\ %F\ %T\ %Z) [NOTICE] - Starting to compress the pre-last dump file $LASTBACKUPFILE on the storage server $(hostname).." >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log 
        mv $LASTBACKUPFILEFULLPATH $DIR/$DIRDATE/$LASTBACKUPFILE && gzip $DIR/$DIRDATE/$LASTBACKUPFILE
        COMPSIZE=$(ls -sh $DIR/$DIRDATE/$LASTBACKUPFILE.gz | awk '{ print $1 }' | sed 's/^\([0-9]*\).*/\1/' 2>/dev/null)
          if [ "$?" -eq 0 ]; then
            echo -e "$(date +%a\ %F\ %T\ %Z) [NOTICE] - Compression completed successfully. A file named $LASTBACKUPFILE.gz has been created. The file size is $COMPSIZE MiB." >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log
          else
            echo -e "$(date +%a\ %F\ %T\ %Z) [ERROR] - Failed to compress file mdb_bkp_${REG[$bcount]}-$FILEDATE.sql. Make sure gzip is installed on the system." >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log
          fi
      fi

      #Checking the integrity of the database dump for expected values
      echo -e "$(date +%a\ %F\ %T\ %Z) [NOTICE] - Checking the integrity of the database dump file mdb_bkp_${REG[$bcount]}-$FILEDATE.sql for expected values.." >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log
      if [ "$STARTDUMP" = "MariaDB" ]
      then
        echo -e "$(date +%a\ %F\ %T\ %Z) [NOTICE] - At the BEGINING of the database dump mdb_bkp_${REG[$bcount]}-$FILEDATE.sql, the expected value was successfully found. Checking the end of the file.." >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log
      else
        echo -e "$(date +%a\ %F\ %T\ %Z) [ERROR] - The expected value was not found at the BEGINING of the database dump file mdb_bkp_${REG[$bcount]}-$FILEDATE.sql. It may be empty or the file may be damaged. Please check and try again." >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log
        rm -f $DIR/$DIRDATE/mdb_bkp_${REG[$bcount]}-$FILEDATE.sql
        echo -e "$(date +%a\ %F\ %T\ %Z) [WARNING] - The region ${REG[$bcount]} with IP ${VIP[$bcount]} dump file is deleted!" >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log
        echo -e "$(date +%a\ %F\ %T\ %Z) [WARNING] - Region ${REG[$bcount]} is excluded from further processing!" >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log
        unset "VIP[$bcount]" && unset "REG[$bcount]"
        continue
      fi

      if [ "$ENDDUMP" = "completed" ]
      then
        echo -e "$(date +%a\ %F\ %T\ %Z) [NOTICE] - At the END of the database dump mdb_bkp_${REG[$bcount]}-$FILEDATE.sql, the expected value was successfully found." >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log
        echo -e "$(date +%a\ %F\ %T\ %Z) [NOTICE] - Checking the integrity of the database dump file mdb_bkp_${REG[$bcount]}-$FILEDATE.sql based on the expected values has been completed. Continue.." >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log
      else
        echo -e "$(date +%a\ %F\ %T\ %Z) [ERROR] - The expected value was not found at the end of the database dump file mdb_bkp_${REG[$bcount]}-$FILEDATE.sql. The file is most likely damaged. Please check and try again." >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log
        rm -f $DIR/$DIRDATE/mdb_bkp_${REG[$bcount]}-$FILEDATE.sql
        echo -e "$(date +%a\ %F\ %T\ %Z) [WARNING] - The region ${REG[$bcount]} with IP ${VIP[$bcount]} dump file is deleted!" >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log
        echo -e "$(date +%a\ %F\ %T\ %Z) [WARNING] - Region ${REG[$bcount]} is excluded from further processing!" >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log
        unset "VIP[$bcount]" && unset "REG[$bcount]"
        continue
      fi

      #Trying restore base in a test server
      echo -e "$(date +%a\ %F\ %T\ %Z) [NOTICE] - The database dump file mdb_bkp_${REG[$bcount]}-$FILEDATE.sql is being tested on a test host with IP - $TESTDBVIP" >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log
      mysql --host=$TESTDBVIP --user=$TESTDBUSER --password=$TESTDBPASSWD < $DIR/$DIRDATE/mdb_bkp_${REG[$bcount]}-$FILEDATE.sql

        if [ "$?" -eq 0 ]
        then
          echo -e "$(date +%a\ %F\ %T\ %Z) [NOTICE] - The operation to restore the test database from the dump file mdb_bkp_${REG[$bcount]}-$FILEDATE.sql completed with code 0 - success." >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log
          echo -e "$(date +%a\ %F\ %T\ %Z) [NOTICE] - Starting to check the integrity of the recovered data inside the test database with IP - $TESTDBVIP" >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log
        else
          echo -e "$(date +%a\ %F\ %T\ %Z) [ERROR] - An error occurred while restoring the database with IP - $TESTDBVIP from a dump mdb_bkp_${REG[$bcount]}-$FILEDATE.sql. Dump is broken." >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log
          rm -f $DIR/$DIRDATE/mdb_bkp_${REG[$bcount]}-$FILEDATE.sql
          echo -e "$(date +%a\ %F\ %T\ %Z) [WARNING] - The region ${REG[$bcount]} with IP ${VIP[$bcount]} dump file is deleted!" >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log
          echo -e "$(date +%a\ %F\ %T\ %Z) [WARNING] - Region ${REG[$bcount]} is excluded from further processing!" >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log
          unset "VIP[$bcount]" && unset "REG[$bcount]"
          continue
        fi

        #Databases and Tables for checking restored test database server
        echo -e "$(date +%a\ %F\ %T\ %Z) [NOTICE] - Checking the integrity of the test database begins.." >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log

        for i in "${DATABASES[@]}"; do
         mysql --host=$TESTDBVIP --user=$TESTDBUSER --password=$TESTDBPASSWD -e "SELECT * FROM $i" 1>/dev/null 2>>$LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log
          if [ "$?" -eq 0 ]; then 
           echo -e "$(date +%a\ %F\ %T\ %Z) [NOTICE] - A table named $i exists in the database. True. Next check.." >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log
          else 
             echo -e "$(date +%a\ %F\ %T\ %Z) [ERROR] - A table named $i is not exists in the database. A dump file named mdb_bkp_${REG[$bcount]}-$FILEDATE.sql is corrupted. Exit with code 1." >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log
             echo -e "$(date +%a\ %F\ %T\ %Z) [WARNING] - The region ${REG[$bcount]} was broken up in a cycle with dump file mdb_bkp_${REG[$bcount]}-$FILEDATE.sql!" >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log
               break
                fi
                 done 

        STOPPER=$(grep "The region ${REG[$bcount]} was broken up in a cycle with dump file mdb_bkp_${REG[$bcount]}-$FILEDATE.sql!" $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log | sed 's/.*\(mdb_bkp.*\)\!/\1/')

        if [ "$STOPPER" = "mdb_bkp_${REG[$bcount]}-$FILEDATE.sql" ]; then
          rm -rf $DIR/$DIRDATE/mdb_bkp_${REG[$bcount]}-$FILEDATE.sql
          echo -e "$(date +%a\ %F\ %T\ %Z) [WARNING] - The region ${REG[$bcount]} with IP ${VIP[$bcount]} dump file is deleted!" >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log
          echo -e "$(date +%a\ %F\ %T\ %Z) [WARNING] - Region ${REG[$bcount]} is excluded from further processing!" >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log
          unset "VIP[$bcount]" && unset "REG[$bcount]"
        continue
        else
          echo -e "$(date +%a\ %F\ %T\ %Z) [NOTICE] - All databases exist in a file mdb_bkp_${REG[$bcount]}-$FILEDATE.sql restored on a $TESTDBVIP. Next check.." >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log
        fi

        echo -e "$(date +%a\ %F\ %T\ %Z) [NOTICE] - Start checking the number of rows in the key tables to ensure the integrity of the data on the host with IP - $TESTDBVIP." >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log

        for i in "${TABLES[@]}"; do
         COUNT=$(mysql --host=$TESTDBVIP --user=$TESTDBUSER --password=$TESTDBPASSWD -e "SELECT * FROM $i" | wc -l)
          if [ $COUNT -gt 0 ]; then
           echo -e "$(date +%a\ %F\ %T\ %Z) [NOTICE] - The table in the database named $i is not empty. The number of records in the table is $COUNT. True. Next check.." >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log
            else
             echo -e "$(date +%a\ %F\ %T\ %Z) [ERROR] - The table in the database named $i is empty. A dump file named mdb_bkp_${REG[$bcount]}-$FILEDATE.sql is corrupted." >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log
             echo -e "$(date +%a\ %F\ %T\ %Z) [WARNING] - The region ${REG[$bcount]} was broken up in a cycle with dump file mdb_bkp_${REG[$bcount]}-$FILEDATE.sql!" >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log
             break
               fi
                done

        STOPPER=$(grep "The region ${REG[$bcount]} was broken up in a cycle with dump file mdb_bkp_${REG[$bcount]}-$FILEDATE.sql!" $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log | sed 's/.*\(mdb_bkp.*\)\!/\1/')

        if [ "$STOPPER" = "mdb_bkp_${REG[$bcount]}-$FILEDATE.sql" ]; then
          rm -f $DIR/$DIRDATE/mdb_bkp_${REG[$bcount]}-$FILEDATE.sql
          echo -e "$(date +%a\ %F\ %T\ %Z) [WARNING] - The region ${REG[$bcount]} with IP ${VIP[$bcount]} dump file is deleted!" >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log
          echo -e "$(date +%a\ %F\ %T\ %Z) [WARNING] - Region ${REG[$bcount]} is excluded from further processing!" >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log
          unset "VIP[$bcount]" && unset "REG[$bcount]"
        continue
        else
          echo -e "$(date +%a\ %F\ %T\ %Z) [NOTICE] - The integrity check of the database dump named mdb_bkp_${REG[$bcount]}-$FILEDATE.sql completed successfully! The dump is verified." >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log
          echo -e "$(date +%a\ %F\ %T\ %Z) [NOTICE] - Generated md5sum for file mdb_bkp_${REG[$bcount]}-$FILEDATE.sql is $MD5SUM Continue.." >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log 
          echo -e "$(date +%a\ %F\ %T\ %Z) [NOTICE] - The database file dump is prepared for sending to the Master Backup Server with IP $MBSIP and hostname $MBSHOST.." >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log
        fi

        #If dump creation and verification - successfully, then put backup on the master backup server
        /usr/openv/netbackup/bin/bpbackup -p "MariaDB" -s "User" -S "pd15lnxbkp01" -L "$LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log" -w 0 $DIR/$DIRDATE/mdb_bkp_${REG[$bcount]}-$FILEDATE.sql 2>> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log

        if [ "$?" -eq 0 ]
        then
          echo -e "$(date +%a\ %F\ %T\ %Z) [NOTICE] - A dump of the database file named mdb_bkp_${REG[$bcount]}-$FILEDATE.sql has been successfully sent to the $MBSHOST host with IP - $MBSIP." >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log
  
            if [ "$LASTHOUR" != "23" ]; then
              mv $DIR/$DIRDATE/mdb_bkp_${REG[$bcount]}-$FILEDATE.sql $DIR/$DIRDATE/last_mdb_bkp_${REG[$bcount]}-$FILEDATE.sql
              echo -e "$(date +%a\ %F\ %T\ %Z) [NOTICE] - The new database file is now the last file that was created in the last hour. File name last_mdb_bkp_${REG[$bcount]}-$FILEDATE.sql." >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log
            else
              echo -e "$(date +%a\ %F\ %T\ %Z) [NOTICE] - The database dump file named $DIR/$DIRDATE/mdb_bkp_${REG[$bcount]}-$FILEDATE.sql is the last one for today. Starting to compress.." >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log
              gzip $DIR/$DIRDATE/mdb_bkp_${REG[$bcount]}-$FILEDATE.sql
              LASTHOURSIZE=$(find $DIR/$DIRDATE/ -type f -name "mdb_bkp_${REG[$bcount]}-$FILEDATE.sql.gz" | xargs ls -sh | awk '{ print $1 }' | sed 's/^\([0-9]*\).*/\1/' 2>/dev/null)
                  if [ "$?" -eq 0 ]; then
                    echo -e "$(date +%a\ %F\ %T\ %Z) [NOTICE] - Compression of the last backup for 23 hours was successful. New filename mdb_bkp_${REG[$bcount]}-$FILEDATE.sql.gz. Size is $LASTHOURSIZE MiB." >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log
                  else
                    echo -e "$(date +%a\ %F\ %T\ %Z) [ERROR] - Failed to compress file mdb_bkp_${REG[$bcount]}-$FILEDATE.sql. Make sure gzip is installed on the system." >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log
                  fi
            fi
        else
          echo -e "$(date +%a\ %F\ %T\ %Z) [ERROR] - An error occurred while sending a file mdb_bkp_${REG[$bcount]}-$FILEDATE.sql name to host $MBSHOST with IP - $MBSIP." >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log
            
            if [ "$LASTHOUR" != "23" ]; then
              mv $DIR/$DIRDATE/mdb_bkp_${REG[$bcount]}-$FILEDATE.sql $DIR/$DIRDATE/last_mdb_bkp_${REG[$bcount]}-$FILEDATE.sql
              echo -e "$(date +%a\ %F\ %T\ %Z) [NOTICE] - The new database file is now the last file that was created in the last hour. File name last_mdb_bkp_${REG[$bcount]}-$FILEDATE.sql." >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log
            else
              echo -e "$(date +%a\ %F\ %T\ %Z) [NOTICE] - The database dump file named $DIR/$DIRDATE/mdb_bkp_${REG[$bcount]}-$FILEDATE.sql is the last one for today. Starting to compress.." >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log
              gzip $DIR/$DIRDATE/mdb_bkp_${REG[$bcount]}-$FILEDATE.sql
              LASTHOURSIZE=$(find $DIR/$DIRDATE/ -type f -name "mdb_bkp_${REG[$bcount]}-$FILEDATE.sql.gz" | xargs ls -sh | awk '{ print $1 }' | sed 's/^\([0-9]*\).*/\1/' 2>/dev/null)
                  if [ "$?" -eq 0 ]; then
                    echo -e "$(date +%a\ %F\ %T\ %Z) [NOTICE] - Compression of the last backup for 23 hours was successful. New filename mdb_bkp_${REG[$bcount]}-$FILEDATE.sql.gz. Size is $LASTHOURSIZE MiB." >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log
                  else
                    echo -e "$(date +%a\ %F\ %T\ %Z) [ERROR] - Failed to compress file mdb_bkp_${REG[$bcount]}-$FILEDATE.sql. Make sure gzip is installed on the system." >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log
                  fi
            fi
          fi

    else
      echo -e "$(date +%a\ %F\ %T\ %Z) [ERROR] - Database dump mdb_bkp_${REG[$bcount]}-$FILEDATE.sql collection operation completed with errors." >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log
      rm -f $DIR/$DIRDATE/mdb_bkp_${REG[$bcount]}-$FILEDATE.sql 2>/dev/null
      echo -e "$(date +%a\ %F\ %T\ %Z) [WARNING] - The region ${REG[$bcount]} with IP ${VIP[$bcount]} dump file is deleted!" >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log
      echo -e "$(date +%a\ %F\ %T\ %Z) [WARNING] - Region ${REG[$bcount]} is excluded from further processing!" >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log
      unset "VIP[$bcount]" && unset "REG[$bcount]"
    fi
done

#Checking for old directories and delete if find
echo -e "$(date +%a\ %F\ %T\ %Z) [NOTICE] - Start checking old files and directories on the storage server $(hostname).." >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log 

if [ "$WHEREOLD" != "" ]; then
  echo -e "$(date +%a\ %F\ %T\ %Z) [WARNING] - Old files was found. Removing them with contains files.." >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log
  rm -f $WHEREOLD 1>/dev/null 2>>$LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log
  find $WORKDIR/* -type d -empty | xargs rm -rf
  echo -e "$(date +%a\ %F\ %T\ %Z) [NOTICE] - All old files and directories have been removed." >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log
else
  echo -e "$(date +%a\ %F\ %T\ %Z) [NOTICE] - Old files or directories is not found. Nothing to do." >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log
fi

#Summary info
REG=("srv-msrv-001" "srv-msrv-002" "etc")
echo -e "$(date +%a\ %F\ %T\ %Z) [INFO] - Printing summary information about created backups:" >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log

for (( bcount=0; bcount < 18; bcount++ )); do
  SUMMARY=$(find $DIR/$DIRDATE/ -type f -name "last_mdb_bkp_${REG[$bcount]}*" | sed 's/^\/.*\(last_mdb_bkp.*\)/\1/' 2>/dev/null)
  FULLSUMMARY=$(find $DIR/$DIRDATE/ -type f -name "last_mdb_bkp_${REG[$bcount]}*" 2>/dev/null)
  if [ -f "$FULLSUMMARY" ]; then
  echo -e "$(date +%a\ %F\ %T\ %Z) [INFO] - Last created backup file for ${REG[$bcount]} is - $SUMMARY" >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log
  else
  echo -e "$(date +%a\ %F\ %T\ %Z) [INFO] - A file named $SUMMARY for a region ${REG[$bcount]} was not created." >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log
  fi
done

#Exit
echo -e "$(date +%a\ %F\ %T\ %Z) [NOTICE] - All tasks have been completed successfully. Exit code 0 - Success." >> $LOGDIR/$DIRDATE/mdb_bkp-$DIRDATE.log
rm -f $PFPID/backup_mdb-$FILEDATE.pid
exit 0
