#!/bin/bash

# Interactive initialization script for phoenixd/lnbits stack

set -eEo pipefail
source initlib.sh

cd $( dirname $0 )

# Check if the script is being run as root
if [ ! "$(id -u)" -eq 0 ]; then
    echo "This script needs root priviledges. Run it using sudo."
    exit 1
fi

# # Check if ufw is installed
# if ! command -v ufw &> /dev/null; then
#     echo "ufw Firewall is not installed on this system. Please install and run again."
#     exit 1
# fi

# # Check if ufw is active
# if ! ufw status | grep -q "Status: active"; then
#     echo "ufw Firewall is not active. Please enable ufw first."
#     exit 1
# fi

# Migration path
if [[ -d data && -d letsencrypt && -d lnbitsdata && -f .env && -f default.conf && -f docker-compose.yml ]]; then
    echo ">>>A previous installation was detected<<<"
    echo
    echo "In order to use the new multistack enhancements, you need first to migrate your running environment."
    echo "All configurations and data will be preserved."
    echo
    read -p "Do you want to continue? (y/N): " migrateyesno
    echo
    
    if [[ ! $migrateyesno =~ ^[Yy]$ ]]; then
        echo "Bye"
        exit 0
    fi

    # Stop all containers
    echo "Stopping all containers..."
    docker compose down
    echo "All containers have been stopped."

    # Backup configurations and data
    echo "Backing up configuration and data..."
    mkdir -p .backup
    mv -t .backup data letsencrypt lnbitsdata .env default.conf docker-compose.yml
    if [[ -d pgdata ]]; then
        mv pgdata .backup/
    fi
    if [[ -d pgtmp ]]; then
        mv pgtmp .backup/
    fi
    echo "Backup completed"

    # Restore on error
    trap "migration_trap" EXIT

    SID=1
    STACK="stack_$SID"

    mkdir -p nginx $STACK

    # Setup stack
    echo "Migrating configurations and data..."
    cp -R .backup/{data,lnbitsdata,.env} $STACK
    if [[ -d .backup/pgdata ]]; then
        cp -R .backup/pgdata $STACK
    fi
    if [[ -d .backup/pgtmp ]]; then
        cp -R .backup/pgtmp $STACK
    fi
    cp -R .backup/letsencrypt ./

    cp docker-compose.yml.example docker-compose.yml
    sed -i "/^services:/i \ \ - $STACK/docker-compose.yml" docker-compose.yml
    
    if grep -q postgres .backup/docker-compose.yml; then
        POSTGRES_PASSWORD=$( grep POSTGRES_PASSWORD .backup/docker-compose.yml | sed 's/^.*: *//' )
        
        cp docker-compose.yml.stack.example $STACK/docker-compose.yml
        sed -i "s/^\( *POSTGRES_PASSWORD: \).*$/\1$POSTGRES_PASSWORD/" $STACK/docker-compose.yml
        sed -i "s/^\( *postgres\):/\1-$SID:/" $STACK/docker-compose.yml

        update_env "LNBITS_DATABASE_URL" "postgres://postgres:$POSTGRES_PASSWORD@postgres-$SID:5432/lnbits"
    else
        cp docker-compose.yml.stack.sqlite.example $STACK/docker-compose.yml
    fi
    sed -i "s/^\( *phoenixd\):/\1-$SID:/" $STACK/docker-compose.yml
    sed -i "s/^\( *lnbits\):/\1-$SID:/" $STACK/docker-compose.yml
    sed -i "s/^\( *container_name: .*\)$/\1-$SID/" $STACK/docker-compose.yml

    update_env "PHOENIXD_API_ENDPOINT" "http://phoenixd-$SID:9740/"
    update_env "LNBITS_SITE_TAGLINE" "\"free and open-source lightning wallet\""
    update_env "LNBITS_SITE_DESCRIPTION" "\"The world's most powerful suite of bitcoin tools. Run for yourself, for others, or as part of a stack.\""

    # Nginx
    cp .backup/default.conf nginx/$STACK.conf
    sed -i "s/\(http:\/\/phoenixd\)/\1-$SID/" nginx/$STACK.conf
    sed -i "s/\(http:\/\/lnbits\)/\1-$SID/" nginx/$STACK.conf

    # Verify the contents of the updated files
    echo "Relevant contents of the .env file after update:"
    grep -E "^(LNBITS_BACKEND_WALLET_CLASS|PHOENIXD_API_ENDPOINT|PHOENIXD_API_PASSWORD|LNBITS_DATABASE_URL|LNBITS_SITE_TITLE|LNBITS_SITE_TAGLINE|LNBITS_SITE_DESCRIPTION)=" $STACK/.env
    echo
    echo "Relevant contents of the nginx file after update:"
    grep -E "(ssl_certificate|proxy_pass)" nginx/$STACK.conf | sed 's/^ *//'
    echo
    echo "Setup completed."

    # Restart all containers
    echo "Restarting all containers..."
    docker compose up -d

    LNBITS_DOMAIN=$( grep server_name nginx/$STACK.conf | sed -e 's/^ *server_name *//' -e 's/;$//' | tail -1 )
    PHOENIXD_DOMAIN=$( grep server_name nginx/$STACK.conf | sed -e 's/^ *server_name *//' -e 's/;$//' | head -1 )
    
    echo 
    echo "Initialization complete. All containers have been successfully started with the new configurations."
    echo "Your system is now ready for use."
    echo 
    echo "- You can access LNbits at https://$LNBITS_DOMAIN"
    echo "- The Phoenixd API is accessible at https://$PHOENIXD_DOMAIN"
    echo "- To manage the containers, use the docker compose commands in the project directory."
    echo
    echo "In order to view container logs, just use 'docker compose logs [container_name]' or "
    echo "docker compose logs -t -f --tail 300"

    exit 0
fi

# if [[ $1 =~ ^clear$ ]]; then
# 	docker compose stop
# 	docker compose rm
# 	sudo rm -Rf data/ letsencrypt/ lnbitsdata/ pgtmp/ pgdata/ docker-compose.yml default.conf
#         echo "Setup cleared"
#         exit 0
#     fi

# # Check if port 80 is allowed in ufw
# if ufw status | grep -q "80"; then
#     echo "Port $PORT is allowed through ufw."
#     echo "This is OK for the certbot script"
# else
#     echo "Port $PORT is not allowed through ufw."
#     echo "Port 80 status open is necessary to run certbot. Please open and run again"
#     exit 1
# fi
# echo 

# # Request configuration data from the user
# echo ">>>Please provide needed configuration infos<<<"
# echo
# read -p "Enter the domain for Phoenixd API (e.g., api.yourdomain.com): " PHOENIXD_DOMAIN
# read -p "Enter the domain for LNbits (e.g., lnbits.yourdomain.com): " LNBITS_DOMAIN
# read -p "Do you want real Letsencrypt certificates to be issued? (y/n): " letscertificates
# read -p "Do you want LNBits to use PostgreSQL? (y/n): " postgresyesno
# echo

# # Copy example files
# cp default.conf.example default.conf
# if [[ $postgresyesno =~ ^[Yy]$ ]]; then
# 	cp docker-compose.yml.example docker-compose.yml
# 	cp .env.example .env
# else
# 	cp docker-compose.yml.sqlite.example docker-compose.yml
# 	cp .env.sqlite.example .env
# fi

# echo "docker-compose.yml and .env files set up."
# echo 


# # Generate certificates
# if [[ ! $letscertificates =~ ^[Yy]$ ]]; then
#         echo "Issuing selfsigned certificates on local host..."
# 	generate_certificates $PHOENIXD_DOMAIN $LNBITS_DOMAIN
# else
#         echo "Issuing Letsencrypt certificates on local host..."
# 	generate_certificates_certbot $PHOENIXD_DOMAIN $LNBITS_DOMAIN
# fi

# # Generate password for Postgres
# POSTGRES_PASSWORD=$(generate_password)

# # Update the .env file
# echo "Updating the .env file..."

# # Remove or comment out unnecessary variables
# sed -i '/^LNBITS_BACKEND_WALLET_CLASS=/d' .env
# sed -i '/^PHOENIXD_API_ENDPOINT=/d' .env
# sed -i '/^PHOENIXD_API_PASSWORD=/d' .env
# sed -i '/^LNBITS_DATABASE_URL=/d' .env
# sed -i '/^LNBITS_SITE_TITLE=/d' .env
# sed -i '/^LNBITS_SITE_TAGLINE=/d' .env
# sed -i '/^LNBITS_SITE_DESCRIPTION=/d' .env

# # Add or update necessary variables
# update_env "LNBITS_BACKEND_WALLET_CLASS" "PhoenixdWallet"
# update_env "PHOENIXD_API_ENDPOINT" "http://phoenixd:9740/"

# # If no postgresql, there is no LNBITS_DATABASE_URL to configure in .env file
# if [[ $postgresyesno =~ ^[Yy]$ ]]; then
# 	update_env "LNBITS_DATABASE_URL" "postgres://postgres:$POSTGRES_PASSWORD@postgres:5432/lnbits"
# fi

# update_env "LNBITS_SITE_TITLE" "$LNBITS_DOMAIN"
# update_env "LNBITS_SITE_TAGLINE" "free and open-source lightning wallet"
# update_env "LNBITS_SITE_DESCRIPTION" "The world's most powerful suite of bitcoin tools. Run for yourself, for others, or as part of a stack."

# # Add a comment for PHOENIXD_API_PASSWORD
# echo "# PHOENIXD_API_PASSWORD will be set after the first run" >> .env

# echo ".env file updated successfully."

# # Update the docker-compose.yml file
# sed -i "s/POSTGRES_PASSWORD: XXXX/POSTGRES_PASSWORD: $POSTGRES_PASSWORD/" docker-compose.yml

# # Update the default.conf file
# echo "Updating the nginx default.conf file..."
# sed -i "s/server_name n1\.yourdomain\.com;/server_name $PHOENIXD_DOMAIN;/" default.conf
# sed -i "s/server_name lb1\.yourdomain\.com;/server_name $LNBITS_DOMAIN;/" default.conf
# sed -i "s|ssl_certificate /etc/letsencrypt/live/n1\.yourdomain\.com/|ssl_certificate /etc/letsencrypt/live/$PHOENIXD_DOMAIN/|" default.conf
# sed -i "s|ssl_certificate_key /etc/letsencrypt/live/n1\.yourdomain\.com/|ssl_certificate_key /etc/letsencrypt/live/$PHOENIXD_DOMAIN/|" default.conf
# sed -i "s|ssl_certificate /etc/letsencrypt/live/lb1\.yourdomain\.com/|ssl_certificate /etc/letsencrypt/live/$LNBITS_DOMAIN/|" default.conf
# sed -i "s|ssl_certificate_key /etc/letsencrypt/live/lb1\.yourdomain\.com/|ssl_certificate_key /etc/letsencrypt/live/$LNBITS_DOMAIN/|" default.conf

# echo "Configuration completed. "
# echo "Certificates have been generated for $PHOENIXD_DOMAIN and $LNBITS_DOMAIN"

# # Build Docker images
# echo "Building Phoenixd Docker image ..."
# docker build -t massmux/phoenixd -f Dockerfile .

# echo "Getting build Docker images from dockerhub"
# docker pull massmux/lnbits:0.12.11
# docker pull nginx
# docker pull postgres

# echo "Making dir data/"
# mkdir data


# # Start the Postgres container
# if [[ $postgresyesno =~ ^[Yy]$ ]]; then
# 	echo "Starting the Postgres container..."
# 	docker compose up -d postgres

# 	# Wait for Postgres to be ready
# 	echo "Waiting for Postgres to be ready..."
# 	until docker compose exec postgres pg_isready
# 	do
# 	  echo "Postgres is not ready yet. Waiting..."
# 	  sleep 2
# 	done
# 	echo "Postgres is ready."
# fi


# # Start the Phoenixd container
# echo "Starting the Phoenixd container..."
# docker compose up -d phoenixd
# wait_for_container phoenixd

# echo "Waiting phoenixd to write stuffs..."
# sleep 20


# # Start the LNbits container
# echo "Starting the LNbits container..."
# docker compose up -d lnbits
# wait_for_container lnbits


# # Start the Nginx container
# echo "Starting the Nginx container..."
# docker compose up -d nginx
# wait_for_container nginx


# echo "All containers have been started."

# # Wait a bit to allow containers to fully initialize
# echo "Waiting 30 seconds to allow for complete initialization..."
# sleep 30

# # Stop all containers
# echo "Stopping all containers..."
# docker compose down

# echo "All containers have been stopped."

# # Configure phoenix.conf and update .env
# echo "Configuring phoenix.conf and updating .env..."

# # Use the relative path to the current directory
# PHOENIX_CONF="$(pwd)/data/phoenix.conf"

# if [ ! -f "$PHOENIX_CONF" ]; then
#     echo "ERROR: phoenix.conf file not found in $PHOENIX_CONF"
#     echo "Setup aborted!"
#     exit 1
# fi

# # Allow phoenixd to listen from 0.0.0.0 
# if ! grep -q "^http-bind-ip=0.0.0.0" "$PHOENIX_CONF"; then
#     sed -i '1ihttp-bind-ip=0.0.0.0' "$PHOENIX_CONF"
#     echo "http-bind-ip=0.0.0.0 added to phoenix.conf"
# else
#     echo "http-bind-ip=0.0.0.0 already present in phoenix.conf"
# fi

# # Extract Phoenixd password
# PHOENIXD_PASSWORD=$(grep -oP '(?<=http-password=).*' "$PHOENIX_CONF")
# if [ -n "$PHOENIXD_PASSWORD" ]; then
#     echo "Phoenixd password found: $PHOENIXD_PASSWORD"
#     update_env "PHOENIXD_API_PASSWORD" "$PHOENIXD_PASSWORD"
#     echo "PHOENIXD_API_PASSWORD updated in .env file"
# else
#     echo "ERROR: Phoenixd password not found in phoenix.conf"
#     echo "Setup aborted!"
#     exit 1
# fi

# # Verify the contents of the .env file
# echo "Relevant contents of the .env file after update:"
# grep -E "^(LNBITS_BACKEND_WALLET_CLASS|PHOENIXD_API_ENDPOINT|PHOENIXD_API_PASSWORD|LNBITS_DATABASE_URL|LNBITS_SITE_TITLE|LNBITS_SITE_TAGLINE|LNBITS_SITE_DESCRIPTION)=" .env

# echo "Configuration of phoenix.conf and .env update completed."

# echo "Setup completed."
# echo "Postgres password: $POSTGRES_PASSWORD"
# if [[ $postgresyesno =~ ^[Yy]$ ]]; then
# 	echo "Phoenixd password: $PHOENIXD_PASSWORD"
# fi

# # Restart all containers
# echo "Restarting all containers with the new configurations..."
# docker compose up -d

# echo 
# echo "Initialization complete. All containers have been successfully started with the new configurations."
# echo "Your system is now ready for use."
# echo 
# echo "- You can access LNbits at https://$LNBITS_DOMAIN"
# echo "- The Phoenixd API is accessible at https://$PHOENIXD_DOMAIN"
# echo "- To manage the containers, use the docker compose commands in the project directory."
# echo
# echo "In order to view container logs, just use 'docker compose logs [container_name]' or "
# echo "docker compose logs -t -f --tail 300"
