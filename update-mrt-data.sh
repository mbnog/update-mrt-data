#!/bin/bash -e
# This script is intended to be run on a fresh DigitalOcean droplet

# VARIABLES
DATA_PATH=/mnt/volume_tor1_01
DATA_DISK=/dev/disk/by-id/scsi-0DO_Volume_volume-tor1-01
### TODO ### how do we know what the hour and minute will be?  You may want to instead chop that off the generated file at time of generation ###
MBNOG_URL=https://mbnog-mrt.sfo2.cdn.digitaloceanspaces.com/$(date +%Y_%m)/rib.$(date +%Y%m%d.2016.bz2)
MBASNS_URL=https://bgpdb.ciscodude.net/api/asns/province/mb
CAASNLATEST_URL=https://bgpdb.ciscodude.net/api/asns/
NUMCPUS=$(( $( awk '$1=="processor" && $2==":" {print $3}' /proc/cpuinfo | sort -n | tail -1 ) + 1 ))
export DATA_PATH DATA_DISK MBNOG_URL MBASNS_URL CAASNLATEST_URL NUMCPUS

## Update System - do not parallelize, wait for this to finish!
apt update
apt dist-upgrade -y

## attach volume
( mkdir -p $DATA_PATH && \
  mount -o discard,defaults,noatime $DATA_DISK $DATA_PATH && \
  echo "$DATA_DISK $DATA_PATH ext4 defaults,nofail,discard 0 0" | sudo tee -a /etc/fstab ) &


## Install Misc software
(  apt install -y axel htop mariadb-{server,client} python-{pymysql,ipy} pigz pbzip2 mydumper; 
   axel -q https://stuff.ciscodude.net/.tools/bgpscanner_1.0-1_20190320_amd64.deb &
   axel -q https://stuff.ciscodude.net/.tools/libisocore1_1.0-1_20190320_amd64.deb &
   wait
   dpkg -i libisocore1_1.0-1_20190320_amd64.deb bgpscanner_1.0-1_20190320_amd64.deb ) &

## make mysql user and DB
( mysqladmin -uroot create bgpdb && \
  mysql -uroot -e "create user bgpdb identified by 'password'; GRANT ALL privileges ON `bgpdb`.* TO 'bgpdb'@'%';" && \
  mysqladmin -uroot flush-privileges; )

wait

# BGP Processing

## get MRT Data and process in parallel
cd $data_path
( axel -q http://data.ris.ripe.net/rrc11/latest-bview.gz && pigz -d latest-bview.gz && bgpscanner latest-bview > ripe-ris-rrc11 ) &
( axel -q $MBNOG_URL && pbzip2 -d  ${MBNOG_URL##*/} && bgpscanner rib.20200410.2016 > mbnog ) &
( axel -q $MBASNS_URL && cut -d\| -f1 mb > mb-asns ) &
( axel -q -o ca-asn-latest.txt $CAASNLATEST_URL ) &
wait

cat > task1.sh <<-__EOF__
  #!/bin/sh
  echo "Stage 1: $1";
  bgpscanner -p "$1\$" rib.20200410.2016 | grep -v 16395:9:0 > routes/$1.routes.txt
  __EOF__
  
cat > task2.sh <<-__EOF__
  #!/bin/sh
  echo "Stage 2: $1";
  bgpscanner -p "$1\$" latest-bview >> routes/$1.routes.txt
  __EOF__

cat > task3.sh <<-__EOF__
  #!/bin/sh
  echo "Stage 3: $1";
  ~/dev/theo/mrt2mysql/mrt2mysql-batchedcommit.py <  $1
  __EOF__

# do the processing in parallel as much as possible (within the limits of shell scripting)
cat ca-asn-latest.txt | xargs -P $NUMCPUS -n 1 task1
rm task1.sh
cat ca-asn-latest.txt | xargs -P $NUMCPUS -n 1 task2
rm task2.sh

# remove empty data, no point in wasting cycles parsing it
find routes/ -empty -name \*.txt -delete

# Final processing
echo routes/*.txt` | xargs -P $NUMCPUS -n 1 task3

## export data
[ -d dumpfiles ] && rmdir -rf dumpfiles
mkdir dumpfiles
mydumper -B bgpdb -o dumpfiles -c --less-locking --no-backup-locks --no-locks -u root -t (( $NUMCPUS / 2 ))
#then I suck this down from my mysql server and import it there to refresh the data
