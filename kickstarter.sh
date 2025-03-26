#!/bin/bash
export DOMAIN=lightstack.yourdomain.com
export EMAIL=tech@yourdomain.com
export ADMIN_USER=admin
export ADMIN_PASS=yourpassword
export NODE_VERSION=20.9.0
git clone -b gui_inst_noninteractive https://github.com/massmux/lightstack.git /home/dev/lightstack
cd /home/dev/lightstack
chmod +x gui-install.sh
chown -R dev:dev /home/dev/lightstack
./gui-install.sh
