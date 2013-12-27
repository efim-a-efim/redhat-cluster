#!/bin/bash

for i in `cat nodes.txt`; do
	echo "Copying $1 to ${i}:$2"
	scp "$1" "${i}:$2"
done
