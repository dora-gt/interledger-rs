#!/usr/bin/env bash

if [[ $1 =~ ^(.*)-v([0-9]+)\.([0-9]+)\.([0-9]+)(-([0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*))?(\+[0-9A-Za-z-]+)?$ ]]; then
    echo ${BASH_REMATCH[1]}
elif [[ $1 =~ ^ilp-node-.*$ ]]; then
    echo "ilp-node"
elif [[ $1 =~ ^ilp-cli-.*$ ]]; then
    echo "ilp-cli"
fi
