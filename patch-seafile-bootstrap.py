#!/usr/bin/env python3
"""Build-time patch for the Seafile image's /scripts/bootstrap.py.

Two first-run fixes for running behind a TLS-terminating proxy (Traefik), both appended to
seahub_settings.py right after the image's own FILE_SERVER_ROOT line:

1. SERVICE_URL. bootstrap.py runs setup-seafile-mysql.py with a hand-built `env=` dict, so
   FORCE_HTTPS_IN_CONF never reaches it and SERVICE_URL is written as http:// even though
   FILE_SERVER_ROOT (written by bootstrap.py itself) gets https://. A later assignment in the
   same settings file wins, so re-state SERVICE_URL with the proto bootstrap.py resolved.
2. CSRF_TRUSTED_ORIGINS. seahub sees plain HTTP while browsers send `Origin: https://<host>`;
   Django 4 (Seafile 11) then rejects every POST, login included, unless that origin is
   trusted. The image never writes this setting.

Fails the build if the anchor line is gone (new Seafile image: re-check the patch).
"""
import sys

path = sys.argv[1] if len(sys.argv) > 1 else "/scripts/bootstrap.py"
anchor = """        fp.write('FILE_SERVER_ROOT = "{proto}://{domain}/seafhttp"'.format(proto=proto, domain=domain))
        fp.write('\\n')
"""
addition = """        # wireguard-ui-stack: see /scripts/patch-seafile-bootstrap.py
        fp.write('SERVICE_URL = "{proto}://{domain}"'.format(proto=proto, domain=domain))
        fp.write('\\n')
        fp.write('CSRF_TRUSTED_ORIGINS = ["{proto}://{domain}"]'.format(proto=proto, domain=domain))
        fp.write('\\n')
"""
src = open(path).read()
if "CSRF_TRUSTED_ORIGINS" in src:
    print(f"{path}: already patched")
    sys.exit(0)
if src.count(anchor) != 1:
    sys.exit(f"{path}: anchor for FILE_SERVER_ROOT not found exactly once; update patch-seafile-bootstrap.py")
open(path, "w").write(src.replace(anchor, anchor + addition, 1))
print(f"{path}: CSRF_TRUSTED_ORIGINS added")
