# Backup scheduler: ofelia (cron for containers) plus the tools backup.sh needs.
# Tiny image, built on the server by `docker compose up` (pull_policy: build in the overlay);
# it is not part of the GHCR build.
ARG OFELIA_IMAGE=mcuadros/ofelia:0.3.22
FROM ${OFELIA_IMAGE}

# openssh-client: upload; tar+gzip: GNU versions (busybox tar has no --warning); mariadb-client:
# consistent dump of the Seafile databases (a raw copy of seafile/db is not restorable).
# tini: PID 1 that reaps the job processes ofelia spawns (0.3.x images ship without it).
RUN apk --no-cache add tini openssh-client tar gzip mariadb-client

COPY entrypoint.sh backup.sh /usr/local/bin/
RUN chmod 755 /usr/local/bin/entrypoint.sh /usr/local/bin/backup.sh

# Renders /etc/ofelia/config.ini from BACKUP_SCHEDULE and execs the ofelia daemon.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD []
