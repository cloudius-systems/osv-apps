#!/bin/bash

THIS_DIR=$(readlink -f $(dirname $0))
CMDLINE=$($THIS_DIR/../cmdline.sh $THIS_DIR 'native')

$THIS_DIR/../../scripts/tests/test_http_app.py \
  -e "$CMDLINE" \
  --guest_port 8080 \
  --host_port 8080 \
  --line 'Started SpringBoot2RestServiceApplication' \
  --http_line 'passportNumber' \
  --http_path '/students'
