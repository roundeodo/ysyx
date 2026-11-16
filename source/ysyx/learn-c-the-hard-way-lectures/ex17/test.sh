#!/bin/bash 
set -e

echo "start automatic test"

rm -f db.dat ex17

make all

./ex17 db.dat c 10 64
./ex17 db.dat s 0 "Frank" "frank@pku.edu.cn"
./ex17 db.dat s 1 "Zed" "zed@shaw.ca"

./ex17 db.dat g 0
./ex17 db.dat l

./ex17 db.dat f "pku"

./ex17 db.dat d 0
if ./ex17 db.dat g 0 2>&1 | grep -q "ID is not set"; then
	    echo "delete successful"
fi

echo "--- all pass ---"
