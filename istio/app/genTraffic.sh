#!/bin/bash

i=1
while true; do
    printf "%s: %d " "$(date '+%H:%M:%S')" "$i"
    curl -s -o /dev/null -w "%{http_code}\n" "http://20.237.160.123:80/productpage"
    i=$((i+1))
    sleep 1
done
