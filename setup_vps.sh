#!/bin/bash

bash ./module/0.init.sh
bash ./module/1.create_user.sh
bash ./module/2.init_ssh.sh
bash ./module/3.init_ufw.sh
#bash ./module/4.init_deploy.sh

systemctl restart ssh
systemctl restart sshd
