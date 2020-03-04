#!/usr/bin/env bash
#
# Copyright (C) 2020, Christian Stenzel, <christianstenzel@linux.com>
#
# Purpose:
#
#
# Editor settings:
# tabstops=4	/ set ts=4
# shiftwidth=4	/ set sw=4

declare fqdn="www.cstenzel.com"
declare sld=${fqdn#www.}			# sagesutra2.com
declare domainlabel=${sld%.*}		# sagesutra2

#                                                                        MAIN()
#
# main control function
###############################################################################
main()
{
	local -r package="mongodb-org"

	# ONLY IN DEV
	remove_installation

	install_package_dependencies

	if ! is_apt_package_installed "$package";
	then
		install_mongodb_package "$package"
		setup_mongo_database
	fi

	create_www_folders
	clone_git_reps
	install_javascript_dependencies
	configure_frontend
	configure_backend
	build_frontend
	setup_nginx
	install_certbot

	# install certificates via letscert
	sudo certbot --quiet --non-interactive --nginx \
		--domain cstenzel.com \
		--domain www.cstenzel.com \
		--domain admin.cstenzel.com

	# restart nginx
	sudo service nginx restart

	# install startup scripts
	start_backend
	start_frontend
	pm2 save
	bash -c "$(pm2 startup | tail -n 1)"


	return 0 # exit success
}


#                                                           CHECK_CONFIG_FILE()
#
# checks config file syntax
###############################################################################
check_config_file()
{
	return 0	      # exit success
}

#                                                INSTALL_PACKAGE_DEPENDENCIES()
#
# installs required packages
###############################################################################
install_package_dependencies()
{
	local -r nginx_flavour="light"

	local -r viaapt="git nginx-$nginx_flavour sed coreutils systemd
					 init-system-helpers openssl gnupg wget nodejs"
	local -r vianpm="pm2"

	local package

	log_action_begin_msg "Updating apt database"
	sudo apt-get update &>> "$LOGFILE"
	log_action_end_msg $?

	for package in $viaapt;
	do
		install_apt_package "$package"
	done

	for package in $vianpm;
	do
		install_npm_package "$package"
	done
}


#                                                    IS_APT_PACKAGE_INSTALLED()
#
# verifies installation of apt package
#
# @param[in]	package		package name
# @param[out]	0			package installed
# @param[out]	1			invalid function usage
# @param[out]	2			empty or invalid package name
# @param[out]	3			package not installed
###############################################################################
is_apt_package_installed()
{
	local -r package="$1"

	# check if one parameter was passed
	if (( $# != 1 ));
	then
		log_failure_msg "Invalid function call"
		return 1
	fi

	# check if package specifier empty or only contains spaces
	if [[ -z "${package// }" ]];
	then
		log_failure_msg "Invalid package specifier"
		return 2                # invalid package name
	fi

	if ! dpkg --status "$package" &>> "$LOGFILE";
	then
		return 3                # package not installed
	fi

	return 0                    # package already installed
}

#                                                    IS_NPM_PACKAGE_INSTALLED()
#
# verifies installation of npm package
#
# @param[in]	package		package name
# @param[out]	0			package installed
# @param[out]	1			invalid function usage
# @param[out]	2			empty or invalid package name
# @param[out]	3			package not installed
###############################################################################
is_npm_package_installed()
{
	local -r package="$1"

	# check if one parameter was passed
	if (( $# != 1 ));
	then
		log_failure_msg "Invalid function call"
		return 1
	fi

	# check if package specifier empty or only contains spaces
	if [[ -z "${package// }" ]];
	then
		log_failure_msg "Invalid package specifier"
		return 2                # invalid package name
	fi

	if ! npm list -g "$package" &>> "$LOGFILE";
	then
		return 3                # package not installed
	fi

	return 0                    # package already installed
}


#                                                         INSTALL_APT_PACKAGE()
#
# installs apt package
#
# @param[in]	package		package name
###############################################################################
install_apt_package()
{
	local -r package="$1"

	if ! is_apt_package_installed "$package";
	then
		log_action_begin_msg "Installing $package via apt"
		sudo apt-get -y install "$package" &>> "$LOGFILE"
		log_end_msg $?
	fi
}


#                                                         INSTALL_NPM_PACKAGE()
#
# installs npm package
#
# @param[in]	package		package name
###############################################################################
install_npm_package()
{
	local -r package="$1"

	if ! is_npm_package_installed "$package";
	then
		log_action_begin_msg "Installing $package via npm"
		sudo npm install -g "$package" &>> "$LOGFILE"
		log_end_msg $?
	fi
}


#                                                      INSTALL_MOGODB_PACKAGE()
#
# installs mongodb package
# see https://docs.mongodb.com/manual/tutorial/install-mongodb-on-ubuntu
###############################################################################
install_mongodb_package()
{
	local -r -i port=80
	local -r mongodb_version="4.2"
	local -r lsb_release_name=$(lsb_release -sc)
	local -r apt_source_fn="mongodb-org-$mongodb_version.list"
	local -r apt_source_dir="/etc/apt/sources.list.d/"
	local -r service="mongod"
	local -r mongo_service_fn="$service.service"
	local -r mongo_service_dir="/lib/systemd/system/"

	local -r package="$1"

	# remove artefacts from previous installations
	remove_conf_files

	# create log and lib dir
	if [[ ! -d /var/log/mongodb ]];
	then
		sudo mkdir -p /var/log/mongodb &>> "$LOGFILE"
		sudo chown mongodb:mongodb /var/log/mongodb &>> "$LOGFILE"
	fi

	if [[ ! -d /var/lib/mongodb ]];
	then
		sudo mkdir -p /var/lib/mongodb &>> "$LOGFILE"
		sudo chown mongodb:mongodb /var/lib/mongodb &>> "$LOGFILE"
	fi

	# import public key
	log_action_begin_msg "Import MongoDB public gpg key"
	wget -qO - \
		https://www.mongodb.org/static/pgp/server-"$mongodb_version".asc | \
		sudo apt-key add - &>> "$LOGFILE"
	log_action_end_msg $?

	# create MongoDB list file in /etc/apt/sources.list.d
	log_action_begin_msg "Create MongoDB source list file"
	echo "deb http://repo.mongodb.org/apt/ubuntu \
		$lsb_release_name/mongodb-org/$mongodb_version multiverse" |\
		sudo tee "$apt_source_dir/$apt_source_fn" &>> "$LOGFILE"
	log_action_end_msg $?

	# update rep and install mongodb
	log_action_begin_msg "Updating apt database"
	sudo apt-get update &>> "$LOGFILE"
	log_action_end_msg $?
	install_apt_package "$package"

	# pins current mongodb version
	echo "mongodb-org hold" | sudo dpkg --set-selections
	echo "mongodb-org-server hold" | sudo dpkg --set-selections
	echo "mongodb-org-shell hold" | sudo dpkg --set-selections
	echo "mongodb-org-mongos hold" | sudo dpkg --set-selections
	echo "mongodb-org-tools hold" | sudo dpkg --set-selections

	# create mongo db system service
	cat <<-EOF | \
	sudo tee -a /lib/systemd/system/"$mongo_service_fn" >> "$LOGFILE"
		[Unit]
		Description=High-performance, schema-free document-oriented database
		After=network.target
		Documentation=https://docs.mongodb.org/manual

		[Service]
		User=mongodb
		Group=mongodb
		ExecStart=/usr/bin/mongod --quiet --config /etc/mongod.conf

		[Install]
		WantedBy=multi-user.target
	EOF

	# update systemd service
	log_action_begin_msg "Reloading daemon configuration"
	sudo systemctl daemon-reload &>> "$LOGFILE"
	log_action_end_msg $?

	# start MongoDB and add it as a service to be started at boot time
	log_action_begin_msg "Starting $service"
	sudo systemctl start "$service" &>> "$LOGFILE"
	log_action_end_msg $?
	log_action_begin_msg "Enabling $service"
	sudo systemctl enable "$service" &>> "$LOGFILE"
	log_action_end_msg $?

	# wait five secs for service startup
	sleep 5

	log_action_begin_msg "Check status of $service"
	if ! sudo systemctl status "$service" &>> "$LOGFILE";
	then
		log_action_end_msg 1
		return 1
	else
		log_action_end_msg 0
		return 0
	fi
}


#                                                        SETUP_MONGO_DATABASE()
#
# inital database setup
###############################################################################
setup_mongo_database()
{
	local -r username="admin"
	local -r password="admin123"
	local -r db="admin"
	local -r service="mongod"

	log_action_begin_msg "Deleting MongoDB user $username"
	mongo --quiet --eval "
	db=db.getSiblingDB(\"$db\");
	db.dropUser(\"$username\")
	" &>> "$LOGFILE"
	log_action_end_msg $?

	log_action_begin_msg "Adding inital user $username to database"
	mongo --quiet --eval "
		db=db.getSiblingDB(\"$db\");
		db.createUser({
		user:\"$username\", \
		pwd:\"$password\", \
		roles:[{role:'root', db:'$db'}]
	})" &>> "$LOGFILE"
	log_action_end_msg $?

	log_action_begin_msg "Adapting $service configuration"
	pattern="^ExecStart=.*$"
	repl="ExecStart=/usr/bin/mongod --quiet --auth --config /etc/mongod.conf"
	sudo sed -i \
		"s/$pattern/${repl//\//\\/}/" \
		/lib/systemd/system/mongod.service
	log_action_end_msg $?

	# reloading service
	log_action_begin_msg "Reloading daemon configuration"
	sudo systemctl daemon-reload &>> "$LOGFILE"
	log_action_end_msg $?

	log_action_begin_msg "Restarting $service"
	sudo service "$service" restart
	log_action_end_msg $?

	return 0
}


#                                                       CREATE_REMOTE_FOLDERS()
###############################################################################
create_www_folders()
{
	local -r basedir="/var/www/$domainlabel"
	local -r backenddir="backend"
	local -r frontenddir="frontend"

	[[ ! -d "$basedir" ]] && sudo mkdir -p "$basedir"

	if [[ ! -d "$basedir/$backenddir" ]];
	then
		sudo mkdir -p "$basedir/$backenddir"
		sudo chown -R "$USER:$(id --group --name)" "$basedir/$backenddir"
	else
		# what to do here ? -> test if content is gitdir and has correct origin
		# then git pull
		:
	fi

	if [[ ! -d "$basedir/$frontenddir" ]];
	then
		sudo mkdir -p "$basedir/$frontenddir"
		sudo chown -R "$USER:$(id --group --name)" "$basedir/$frontenddir"
	else
		# what to do here ? -> test if content is gitdir and has correct origin
		# then git pull
		:
	fi
}


#                                                              CLONE_GIT_REPS()
###############################################################################
clone_git_reps()
{
	local -r basedir="/var/www/$domainlabel"
	local -r backenddir="backend"
	local -r backenduri="https://github.com/Anas-MI/cbdbene-backend.git"
	local -r frontenddir="frontend"
	local -r frontenduri="https://github.com/shubhamAyodhyavasi/cbdbenev2.git"

	log_action_begin_msg "Cloning backend"
	if [[ -d "$basedir/$backenddir" ]];
	then
		git -C "$basedir/$backenddir" clone "$backenduri" &>> "$LOGFILE"
	fi
	log_action_end_msg $?

	log_action_begin_msg "Cloning frontend"
	if [[ -d "$basedir/$frontenddir" ]];
	then
		git -C "$basedir/$frontenddir" clone "$frontenduri" &>> "$LOGFILE"
	fi
	log_action_end_msg $?
}


#                                             INSTALL_JAVASCRIPT_DEPENDENCIES()
###############################################################################
install_javascript_dependencies()
{
	local -r basedir="/var/www/$domainlabel"
	local -r backenddir="backend/cbdbene-backend"
	local -r frontenddir="frontend/cbdbenev2"

	local -r curwd="$(pwd)"

	log_action_begin_msg "Install frontend dependencies"
	cd "$basedir/$frontenddir" || return 1
	npm update &>> "$LOGFILE"
	log_action_end_msg $?
	cd "$curwd" || return 1

	log_action_begin_msg "Install backend dependencies"
	cd "$basedir/$backenddir" || return 1
	npm update &>> "$LOGFILE"
	log_action_end_msg $?
	cd "$curwd" || return 1

	return 0
}


#                                                          CONFIGURE_FRONTEND()
###############################################################################
configure_frontend()
{
	adapt_frontend_port
	adapt_frontend_url
}


#                                                         ADAPT_FRONTEND_PORT()
###############################################################################
adapt_frontend_port()
{
	local -i port=3007
	local -r pattern1='"dev": "next dev"'
	local -r pattern2='"start": "next start"'
	local -r basedir="/var/www/$domainlabel"
	local -r frontenddir="frontend/cbdbenev2"
	local -r conffile="$basedir/$frontenddir/package.json"

	log_action_begin_msg "Adapting frontend port"
	sed -i "s/$pattern1/${pattern1:0:-1} -p $port\"/" "$conffile"
	sed -i "s/$pattern2/${pattern2:0:-1} -p $port\"/" "$conffile"
	log_action_end_msg $?
}


#                                                          ADAPT_FRONTEND_URL()
###############################################################################
adapt_frontend_url()
{
	local -r basedir="/var/www/$domainlabel"
	local -r frontenddir="frontend/cbdbenev2"
	local -r conffile="$basedir/$frontenddir/constants/projectSettings.js"

	local -r pattern1="export const baseUrl"
	local -r pattern2="https:\/\/admin.cbdbene.com"
	local -r httpsurl="https:\/\/admin.$domainlabel.com"
	local -r httpurl="http:\/\/admin.$domainlabel.com"

	log_action_begin_msg "Adapting frontend url"
	sed -i "s/^\($pattern1.*= \).*$/\1\"$httpsurl\";/" "$conffile" \
		&>> "$LOGFILE"
	sed -i "s/$pattern2/$httpurl/" "$conffile" &>> "$LOGFILE"
	log_action_end_msg $?
}


#                                                              BUILD_FRONTEND()
###############################################################################
build_frontend()
{
	local -r basedir="/var/www/$domainlabel"
	local -r frontenddir="frontend/cbdbenev2"

	local -r curwd="$(pwd)"
	local -r -i max_runs=10
	local -i successful_build=1

	log_action_begin_msg "Building frontend dependencies"

	cd "$basedir/$frontenddir" || return 1
	# in case insufficient ram repeat build til successful
	for (( i=1; i<=max_runs; i++));
	do
		if npm run build &>> "$LOGFILE";
		then
			successful_build=0
			break;
		fi
	done

	if (( successful_build != 0 ));
	then
		log_action_end_msg 1 
		log_failure_msg "Unable to build frontend. Give up."
		exit 1
	fi

	log_action_end_msg 0 

	cd "$curwd" || return 1
}


#                                                           CONFIGURE_BACKEND()
###############################################################################
configure_backend()
{
	local -r basedir="/var/www/$domainlabel"
	local -r backenddir="backend/cbdbene-backend"
	local -r envfile=".env"
	local -r clienturl="https://$domainlabel.com"
	local -r serverurl="https://$domainlabel.com"
	local -r dbname="admin"
	local -r dbusername="admin"
	local -r dbpassword="admin123"
	local -r dbhostname="localhost"
	local -r -i dbport=27017
	local -r clientid="936223668088-mg6le6oiabj4qrpj82c28dpj8ctf648d.apps.googleusercontent.com"
	local -r clientsecret="gWiuvxeJ4mbddARAdIYsnltc"
	local -r keyid="AKIAJMUJXEIE42GYPGRA"
	local -r region="us-west-2"
	local -r accesskey="n45vnKDW053nk+129lnbyEQkZkCVkN8m20Qs6Js2"
	local -r bucket="new-maxxbio"
	local -r -i serverport=5003

	cat <<-EOF > "$basedir/$backenddir/$envfile"
		PORT=$serverport
		CLIENT_URL="$serverurl"
		serverurl="$clienturl"
		MONGOLAB_URI="mongodb://$dbusername:$dbpassword@$dbhostname:$dbport/$dbname?retryWrites=true&w=majority"
		GOOGLE_CLIENT_ID=$clientid
		GOOGLE_CLIENT_SECRET=$clientsecret
		ACCESSKEYID=$keyid
		REGION=$region
		SECRETACCESSKEY=$accesskey
		BUCKET=$bucket
	EOF
}


#                                                               START_BACKEND()
###############################################################################
start_backend()
{
	local -r basedir="/var/www/$domainlabel"
	local -r backenddir="backend/cbdbene-backend"
	local -r curwd="$(pwd)"
	local -r instance_name="$domainlabel-backend"

	cd "$basedir/$backenddir" || return 1
	log_action_begin_msg "Starting nodejs backend"
	pm2 start "npm start" -n "$instance_name" &>> "$LOGFILE"
	log_action_end_msg $?
	sleep 3
	cd "$curwd" || return 1
}

#                                                              START_FRONTEND()
###############################################################################
start_frontend()
{
	local -r basedir="/var/www/$domainlabel"
	local -r frontenddir="frontend/cbdbenev2"
	local -r curwd="$(pwd)"
	local -r instance_name="$domainlabel-frontend"

	cd "$basedir/$frontenddir" || return 1
	log_action_begin_msg "Starting nodejs frontend"
	pm2 start "npm start" -n "$instance_name" &>> "$LOGFILE"
	log_action_end_msg $?
	sleep 3
	cd "$curwd" || return 1
}


#                                                    GENERATE_SELFSIGNED_CERT()
###############################################################################
generate_selfsigned_cert()
{
	local -r -i valid_days=365
	local -r country="US"
	local -r province="Denial"
	local -r city="Springfield"
	local -r o="Organisation"
	local -r ou="Department"
	local -r domain="$domainlabel.com"
	local -r cn="www.$domain"
	local -r certpath="/etc/letsencrypt/live/$domain"

	if [[ ! -d "$certpath" ]];
	then
		sudo mkdir -p "$certpath"
	fi

	log_action_begin_msg "Creating self signed certificate"
	sudo openssl req \
		-new \
		-newkey rsa:4096 \
		-days $valid_days \
		-nodes \
		-x509 \
		-subj "/C=$country/ST=$province/L=$city/O=$o/OU=$ou/CN=$cn" \
		-keyout "$certpath/privkey.pem" \
		-out "$certpath/fullchain.pem" \
	&>> "$LOGFILE"
	log_action_end_msg $?

	return 0
}

#                                                                 SETUP_NGINX()
###############################################################################
setup_nginx()
{
	local -r domain="$domainlabel.com"
	local -r conffile="/etc/nginx/sites-available/$domain"
	local -r symlink="/etc/nginx/sites-enabled/$domain"
	local -r certpath="/etc/letsencrypt/live/$domain"
	local -r nginx_flavour="light"
	local -r -i frontend_port=3007
	local -r -i backend_port=5003

	log_action_begin_msg "Configure and restart webserver"

	[[ -e "$symlink" ]] && sudo rm "$symlink" &>> "$LOGFILE"
	[[ -f "$conffile" ]] && sudo rm "$conffile" &>> "$LOGFILE"

	cat << EOF \
	| sudo tee -a "$conffile" >> "$LOGFILE"
	server {
		listen 80;
		server_name $domain www.$domain;
		location / {
			return 301 https://\$host\$request_uri;
		}
	}

	server {
		listen 443 ssl;
		listen [::]:443 ssl ;
		server_name $domain www.$domain;
		location / {
			proxy_pass http://localhost:$frontend_port;
			proxy_http_version 1.1;
			proxy_set_header Upgrade \$http_upgrade;
			proxy_set_header Connection 'upgrade';
			proxy_set_header Host \$host;
			proxy_cache_bypass \$http_upgrade;
		}
	}

	server {
		listen 80;
		server_name admin.$domain;
		location / {
			return 301 https://\$host\$request_uri;
		}
	}

	# Point backend domain name to port
	server {
		listen 443 ssl;
		index index.html index.htm index.nginx-debian.html;
		server_name admin.$domain;
		location / {
			proxy_pass http://localhost:$backend_port;
			proxy_http_version 1.1;
			proxy_set_header Upgrade \$http_upgrade;
			proxy_set_header Connection 'upgrade';
			proxy_set_header Host \$host;
			proxy_cache_bypass \$http_upgrade;
		}
	}
EOF

	sudo sed -i "s/^\t//" "$conffile" &>> "$LOGFILE"

	# adapt /etc/host since no access to dns server
	sudo sed -i \
		"s/\(^127\.0\.0\.1.*localhost \).*$/\1 $domain admin.$domain/"\
		/etc/hosts

	sudo ln -s "$conffile" "$symlink" &>> "$LOGFILE"

	sudo service nginx restart &>> "$LOGFILE"

	log_end_msg 0

	return 0
}

#                                                             INSTALL_CERTBOT() 
###############################################################################
install_certbot()
{
	local -r domain="$domainlabel.com"

	install_apt_package software-properties-common
	sudo add-apt-repository -y universe &>> "$LOGFILE"
	sudo add-apt-repository -y ppa:certbot/certbot &>> "$LOGFILE"
	sudo apt-get update &>> "$LOGFILE"

	install_apt_package certbot &>> "$LOGFILE"
	install_apt_package python-certbot-nginx  &>> "$LOGFILE"
}

#                                                           REMOVE_CONF_FILES()
#
# removes mongodb configuration files
# only for testing purposes
###############################################################################
remove_conf_files()
{
	local -r apt_source_fn="mongodb-org-$mongodb_version.list"
	local -r apt_source_dir="/etc/apt/sources.list.d/"
	local -r mongo_service_fn="mongod.service"
	local -r mongo_service_dir="/lib/systemd/system/"

	if [[ -f "$apt_source_dir/$apt_source_fn" ]];
	then
		log_action_begin_msg "Removing source list file $apt_source_fn"
		sudo rm "$apt_source_dir/$apt_source_fn"
		log_action_end_msg $?
	fi

	if [[ -f "$mongo_service_dir/$mongo_service_fn" ]];
	then
		log_action_begin_msg "Removing system service file $mongo_service_fn"
		sudo rm "$mongo_service_dir/$mongo_service_fn"
		log_action_end_msg $?
	fi

	return 0
}


#                                                         REMOVE_INSTALLATION()
#
# removes mongodb installation
# only for testing purposes
###############################################################################
remove_installation()
{
	local -r service="mongod"
	local -r package="mongodb-org"
	local -r mongodb_version="4.2"
	local -r basedir="/var/www/$domainlabel"

	log_action_begin_msg "Stopping system service $service"
	sudo systemctl stop "$service";
	log_action_end_msg 0

	log_action_begin_msg "Removing pm2 processes"
	grep -q "$domainlabel-frontend" < <(pm2 ls) && \
		pm2 delete "$domainlabel-frontend" &>> "$LOGFILE"
	grep -q "$domainlabel-backend" < <(pm2 ls)  && \
		pm2 delete "$domainlabel-backend" &>> "$LOGFILE"
	log_action_end_msg 0

	rm -rf ./*.cert &>> "$LOGFILE"
	rm -rf ./*.key &>> "$LOGFILE"

	if is_apt_package_installed "$package";
	then
		log_action_begin_msg "Deinstalling $package"
		[[ -d /var/log/mongodb ]] && sudo rm -r /var/log/mongodb &>> "$LOGFILE"
		[[ -d /var/lib/mongodb ]] && sudo rm -r /var/lib/mongodb &>> "$LOGFILE"
		sudo apt -y --allow-change-held-packages purge "$package" &>> "$LOGFILE"
		log_action_end_msg $?
	fi

	sudo rm -rf "$basedir"

	remove_conf_files

	# remove certbot
	cron_script="/etc/cron.daily/certbot-renew"
	bin_certbot="/usr/local/bin/certbot-auto"
	cliinit="/etc/letsencrypt/cli.ini"


	[[ -f "$cron_script" ]] && sudo rm "$cron_script"
	[[ -f "$bin_certbot" ]] && sudo rm "$bin_certbot"
	[[ -f "$cliini" ]] && sudo rm "$cliini" 

	# removes pm2 startup scripts
	bash -c "$(pm2 unstartup | tail -n 1)"

	return 0
}


#                                                                          BODY
###############################################################################

# source lsb init function file for advanced log functions
declare -r LOGFILE=$(mktemp /tmp/$(date +"%Y-%m-%d_%T_XXXXXX"))
echo "Detailed log goes to $LOGFILE"

if [[ ! -f /lib/lsb/init-functions ]];
then
	>&2 echo "Error sourcing /lib/lsb/init-functions"
	exit 1
fi
. /lib/lsb/init-functions

# code in here only gets executed if script is run directly on the cmdline
if [ "${BASH_SOURCE[0]}" == "$0" ];
then

	# pass whole parameter list to main
	if ! main "$@";
	then
		log_begin_msg "Script error"
		log_end_msg 1
		exit 1
	fi

fi
