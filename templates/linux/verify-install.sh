#!/bin/bash

(
	echo "INFO: Executing script!"
	bash setup.sh --docker
)

if ! php --version; then
	echo "ERROR: Did php get installed?"
	exit 1
fi

if ! mysql -V; then
  echo "ERROR: Did mysql get installed?"
  exit 2
fi

curl -fSL -o /tmp/test.txt http://localhost/
if ! grep -q "SupportPal" /tmp/test.txt; then
  echo "ERROR: SupportPal is not loading via HTTP"
  exit 3
fi

echo "INFO: Successfully verified!"
