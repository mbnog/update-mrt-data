#!/bin/bash -e
# This script is intended to be run on a fresh DigitalOcean droplet

# VARIABLES
DATA_PATH=/mnt/volume_tor1_01
DATA_DISK=/dev/disk/by-id/scsi-0DO_Volume_volume-tor1-01
export DATA_PATH DATA_DISK

## Update System - do not parallelize, wait for this to finish!
apt update
apt dist-upgrade -y

## attach volume
( mkdir -p $DATA_PATH && \
  mkfs.ext4 $DATA_DISK && \
  mount -o discard,defaults,noatime $DATA_DISK $DATA_PATH && \
  echo "$DATA_DISK $DATA_PATH ext4 defaults,nofail,discard 0 0" | sudo tee -a /etc/fstab ) &


## Install Misc software
apt install -y axel htop mariadb-{server,client} python-{pymysql,ipy} pigz pbzip2
axel -q https://stuff.ciscodude.net/.tools/bgpscanner_1.0-1_20190320_amd64.deb &
axel -q https://stuff.ciscodude.net/.tools/libisocore1_1.0-1_20190320_amd64.deb &
wait
dpkg -i libisocore1_1.0-1_20190320_amd64.deb bgpscanner_1.0-1_20190320_amd64.deb


## make mysql user and DB
mysqladmin -uroot create bgpdb
mysql -uroot -e "create user bgpdb identified by 'password'; GRANT ALL privileges ON `bgpdb`.* TO 'bgpdb'@'%';"
mysqladmin -uroot flush-privileges;

# BGP Processing

## get MRT Data
cd $data_path
axel -q http://data.ris.ripe.net/rrc11/latest-bview.gz &
axel -q https://mbnog-mrt.sfo2.cdn.digitaloceanspaces.com/2020_04/rib.20200410.2016.bz2 &
wait
pigz -d latest-bview.gz
pbzip2 -d rib.20200410.2016.bz2

## process data

bgpscanner rib.20200410.2016 > mbnog
bgpscanner latest-bview > ripe-ris-rrc11 

axel -q https://bgpdb.ciscodude.net/api/asns/province/mb
cut -d\| -f1 mb > mb-asns

task(){
  echo "Stage 1: $1";
  bgpscanner -p "$1\$" rib.20200410.2016 | grep -v 16395:9:0 > routes/$1.routes.txt
}
task2(){
  echo "Stage 2: $1";
  bgpscanner -p "$1\$" latest-bview >> routes/$1.routes.txt
}
task3(){
  echo "Stage 3: $1";
  ~/dev/theo/mrt2mysql/mrt2mysql-batchedcommit.py <  $1
}

N=8
(
for as in `cat ca-asn-latest.txt`; do
  ((i=i%N)); ((i++==0)) && wait
  task "$as" & 
done
for as in `cat ca-asn-latest.txt`; do
  ((i=i%N)); ((i++==0)) && wait
  task2 "$as" & 
done
)

find routes/ -empty -name \*.txt -delete

N=2
(
for as in `ls routes/*.txt`; do
  ((i=i%N)); ((i++==0)) && wait
  task3 "$as" & 
done
)

## export data
mysqldump bgpdb > bgpdb.mysqldump
#then I suck this down from my mysql server and import it there to refresh the data
