#!/bin/bash

# Copyright 2021 Alex Masolin
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

#TODO
#automatic requesterId retrieval
#output in CSV

ARCHIVE_ENABLE=1 # save a local copy of data in the <archive> folder / 1=yes, 0=no
archive="/home/ubuntu/solaredge-webscrape/solaredge-webscrape-archive"
SEcookieFILE="/home/ubuntu/solaredge-webscrape/solaredge-webscrape.cookies"

SOLAREDGE_USER="REDACTED" # solaredge portal username
SOLAREDGE_PASS="REDACTED" # solaredge portal password
SOLAREDGE_SITE_ID="REDACTED" # site id

INFLUX=1 # post data to an influxDB instance / 1=yes, 0=no
DBhost="https://eu-central-1-1.aws.cloud2.influxdata.com" # change this if your instance is on a different host, e.g. 127.0.0.1
DBuser="REDACTED"
DBpwd="REDACTED"
DBname="your_db_name"
DBmeasurement="solaredge-webscrape"

# Solaredge portal saves the power optimizers data not based on their serial number (e.g. 21211C18-3F) but based in their requesterId (e.g. 95155874)
# This is a lookup table to match the power optimizer ID with the requesterId
# Change these values with your own! In place of the power optimizer ID you can put any label.
declare -A POid=( ["95155874"]="21211C18-3F" ["95155875"]="21211C19-2F" \
                  ["95155876"]="21211D28-12" ["95155877"]="2123A089-47" )

# ********* DO NOT CHANGE ANYTHING UNDER THIS LINE *************
nowtime=$(date "+%y%m%d%H%M%S")
tmpfolder="/tmp/SEscrape2influx/$nowtime"

function usage {
    echo "usage: $0 [date]"
    echo "  date      date to download in format \"YYYY-MM-DD\""
    echo "  if no date is specified, it will download the 24h data starting yesterday midnight"
    echo "*************************"
    echo
}

if [  $# == 1 ] ; then 
    beginning="$1"
else
    usage
    beginning="yesterday 00:00"
fi

# Solaredge cookie session is valid for 20 days only. Remove cookie file if older than 15 days
find $SEcookieFILE -type f -mtime +15 -delete 

# Create cookie file if doesn't already exist
if [ ! -f "$SEcookieFILE" ]; then
echo "Getting authorization token"
cookie=$(curl --silent --location --request POST 'https://monitoring.solaredge.com/solaredge-apigw/api/login' \
    --header 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode "j_username=$SOLAREDGE_USER" \
    --data-urlencode "j_password=$SOLAREDGE_PASS" \
    --cookie-jar "$SEcookieFILE")
fi

startDate=$(($(date -d "$beginning" '+%s')*1000))
endDate=$(($(date -d "$beginning + 1day" "+%s")*1000))
archiveDate=$(date -d "$beginning" "+%y%m%d")

declare -a parameterName=( Current Energy Voltage PowerBox%20Voltage Power )
mkdir -p "$tmpfolder"
mkdir -p "$archive"

for key in "${!POid[@]}"; do
    for parameter in "${parameterName[@]}"; do
    LPfilename="${archiveDate}_solaredge_webscrape.lp"
    JSONfilename="${archiveDate}_solaredge_webscrape.json"
    LPoutput="$tmpfolder/$LPfilename"
    JSONoutput="$tmpfolder/$JSONfilename"
    PO_id=${POid[${key}]}
    reporterId=${key}
    echo -ne "Downloading $PO_id($parameter) for $(date -d "$beginning"): "
    response=$(curl -b - --silent --output "$JSONoutput" --write-out '\nHTTP_CODE:%{response_code}\n' -b "$SEcookieFILE" --location --request GET "https://monitoring.solaredge.com/solaredge-web/p/chartData?fieldId=$SOLAREDGE_SITE_ID&startDate=$startDate&endDate=$endDate&reporterId=$reporterId&parameterName=$parameter")
    echo -ne "$response" | grep HTTP_CODE | tr '\n' '\0'
    responseParsed=$(jq --raw-output '.dateValuePairs[] | [.value , .date] | join (", ")' < "$JSONoutput")
    if [ -z "$responseParsed" ]; then
        echo " -> jq skipped (JSON empty)"
    else
        echo -ne " - jq done"
        while read -r line; do
            value=$(awk '{split($0,a,","); printf "%.3f\n", a[1]; }' <<< "$line")
            epoch=$(awk '{split($0,a,","); print a[2]/1000; }' <<< "$line")
            echo "$DBmeasurement,POid=$PO_id $parameter=$value $epoch" >> "$LPoutput"
        done <<< "$responseParsed"
        echo " - LP parsing done"
    fi
    done
done

if [ ! -f "$LPoutput" ]; then
    echo "Line protocol file does not exist (all JSON response empty?). Nothing to do. Exiting. ($LPoutput)"
    exit
fi

if [ "$INFLUX" -eq 1 ] ; then
    echo -ne "*** Posting file to database: $LPoutput ==> "
    OK_response=$'HTTP/2 204 \r'
    # OK_response=$'HTTP/1.1 204 No Content\r'
    longresponse=$(curl -s -i -XPOST "$DBhost/write?db=$DBname&u=$DBuser&p=$DBpwd&precision=s" --data-binary @"$LPoutput");
    response=$(echo "$longresponse" | grep -e "204" | tr -d '\n')
    # echo "$longresponse"
    if [ "${response}" = "${OK_response}" ]; then
        ERROR=0
        echo "$response"
        logger -p6 "$0 INFO-SEscrape: Database entry successfull."
    else
        ERROR=1
        echo "$response"; echo "$longresponse"
        logger -p3 "$0 ERROR-SEscrape: Error writing in the database. Server response code: ${longresponse}"
    fi
else
    ERROR=0
    echo "NO INFLUX"
fi

if [ "$ARCHIVE_ENABLE" -eq 1 ]; then
    if [ "$ERROR" -eq 0 ]; then
        if zip -j -8 "$archive/${archiveDate}_SEscrape_backup.zip" "$LPoutput"; then rm "$LPoutput"; else ERROR=1; fi
        if zip -j -8 "$archive/${archiveDate}_SEscrape_backup.zip" "$JSONoutput"; then rm "$JSONoutput"; else ERROR=1; fi
    fi
    if [ "$ERROR" -eq 1 ]; then
        echo "*** ERROR. Moving LP and JSON file in archive folder"
        mv "$LPoutput" "$archive/${archiveDate}_SEscrape.notprocessed-$nowtime".lp
        mv "$JSONoutput" "$archive/${archiveDate}_SEscrape.notprocessed-$nowtime".json
    fi
else
    echo "NO ARCHIVE"
fi

