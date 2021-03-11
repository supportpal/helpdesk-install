#!/bin/bash

(
	echo "INFO: Executing script!"
	bash setup.sh
)

if ! php --version; then
	echo "ERROR: Did php get installed?"
	exit 1
fi

curl -fSL -o /tmp/test.txt http://localhost/
if ! grep -q "SupportPal" /tmp/test.txt; then
  echo "ERROR: SupportPal is not loading via HTTP"
  exit 2
fi

echo "INFO: Successfully verified!"
