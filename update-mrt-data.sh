# BGP Processing

data_path = /mnt/volume_tor1_01

## Update System
apt update
apt upgrade -y

## Install Misc software
apt install -y curl htop mariadb-{server,client} python-{pymysql,ipy}
#apt install python-virtualenv
#wget https://www.isolario.it/tools/bgpscanner_1.0-1_20190320_amd64.deb https://www.isolario.it/tools/libisocore1_1.0-1_20190320_amd64.deb
wget https://stuff.ciscodude.net/.tools/bgpscanner_1.0-1_20190320_amd64.deb https://stuff.ciscodude.net/.tools/libisocore1_1.0-1_20190320_amd64.deb
dpkg -i libisocore1_1.0-1_20190320_amd64.deb bgpscanner_1.0-1_20190320_amd64.deb

## make mysql user and DB

mysql
 create database bgpdb;
 create user bgpdb identified by 'password';
 GRANT ALL privileges ON `bgpdb`.* TO 'bgpdb'@'%';
 flush privileges;

## attach volume
mkdir -p /mnt/volume_tor1_01 
mount -o discard,defaults,noatime /dev/disk/by-id/scsi-0DO_Volume_volume-tor1-01 /mnt/volume_tor1_01
echo '/dev/disk/by-id/scsi-0DO_Volume_volume-tor1-01 /mnt/volume_tor1_01 ext4 defaults,nofail,discard 0 0' | sudo tee -a /etc/fstab


## get MRT Data
cd $data_path
wget http://data.ris.ripe.net/rrc11/latest-bview.gz https://mbnog-mrt.sfo2.cdn.digitaloceanspaces.com/2020_04/rib.20200410.2016.bz2
gunzip latest-bview.gz
bunzip2 rib.20200410.2016.bz2

## process data

bgpscanner rib.20200410.2016 > mbnog
bgpscanner latest-bview > ripe-ris-rrc11 

curl -s https://bgpdb.ciscodude.net/api/asns/province/mb > mb
cut -d\| -f1 mb > mb-asns

#!/bin/bash

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
