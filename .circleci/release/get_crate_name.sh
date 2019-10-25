#!/usr/bin/env bash

if [[ $1 =~ ^(.*)-v([0-9]+)\.([0-9]+)\.([0-9]+)(-([0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*))?(\+[0-9A-Za-z-]+)?$ ]]; then
  echo ${BASH_REMATCH[1]}
fi
