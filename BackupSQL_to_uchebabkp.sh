#!/bin/bash

mysqldump \
--defaults-extra-file=/root/.my.cnf \
--all-databases \
--single-transaction \
--routines \
--triggers \
--events \
--set-gtid-purged=OFF |
gzip |
ssh ubackup@10.10.93.239 \
"cat > /srv/backup/$(hostname)_mysql_$(date +%Y%m%d_%H%M%S).sql.gz"
