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
#     echo "ufw Firewall is not installed on this system. Please install and run again." >&2
#     exit 1
# fi

# # Check if ufw is active
# if ! ufw status | grep -q "Status: active"; then
#     echo "ufw Firewall is not active. Please enable ufw first." >&2
#     exit 1
# fi

# Check if Certbot is installed
if ! command -v certbot &> /dev/null; then
    echo "Certbot is not installed. Please install Certbot and try again." >&2
    exit 1
fi
    
# # Check if port 80 is allowed in ufw
# if ! ufw status | grep -q "80"; then
#     echo "Port $PORT is not allowed through ufw." >&2
#     echo "Port 80 status open is necessary to run certbot. Please open and run again" >&2
#     exit 1
# fi
# echo

SID=$(generate_stack_id)
STACK="stack_$SID"

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
        exit 0
    fi

    # Stop all containers
    echo "Stopping all containers..."
    docker compose down
    echo "All containers have been stopped."

    # Backup configurations and data
    echo "Backing up configuration and data..."
    mkdir -p .backup
    mv -t .backup data lnbitsdata .env default.conf docker-compose.yml
    if [[ -d pgdata ]]; then
        mv pgdata .backup/
    fi
    if [[ -d pgtmp ]]; then
        mv pgtmp .backup/
    fi
    echo "Backup completed"

    # Restore on error
    trap "exit 128" SIGINT
    trap "exit 129" SIGQUIT
    trap "exit 143" SIGTERM
    trap "migration_trap" EXIT

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
    sed -i "s/^\( *postgres\):/\1-$SID:/" $STACK/docker-compose.yml
    sed -i "s/^\( *container_name: .*\)$/\1-$SID/" $STACK/docker-compose.yml

    update_env "PHOENIXD_API_ENDPOINT" "http://phoenixd-$SID:9740/"
    update_env "LNBITS_SITE_TAGLINE" "\"free and open-source lightning wallet\""
    update_env "LNBITS_SITE_DESCRIPTION" "\"The world's most powerful suite of bitcoin tools. Run for yourself, for others, or as part of a stack.\""

    # Nginx
    cp .backup/default.conf nginx/$STACK.conf
    sed -i "s|\(http://phoenixd\)|\1-$SID|" nginx/$STACK.conf
    sed -i "s|\(http://lnbits\)|\1-$SID|" nginx/$STACK.conf

    # Verify the contents of the updated files
    echo
    echo "Relevant contents of the nginx/$STACK.conf file after update:"
    grep -E "(server_name|ssl_certificate|proxy_pass)" nginx/$STACK.conf | sed 's/^ *//'
    echo
    echo "Relevant contents of the $STACK/.env file after update:"
    grep -E "^(LNBITS_BACKEND_WALLET_CLASS|PHOENIXD_API_ENDPOINT|PHOENIXD_API_PASSWORD|LNBITS_DATABASE_URL|LNBITS_SITE_TITLE|LNBITS_SITE_TAGLINE|LNBITS_SITE_DESCRIPTION)=" $STACK/.env
    echo
    echo "Migration completed."

    # Restart all containers
    echo "Restarting all containers..."
    docker compose up -d
    echo "All containers have been started."

    # Verify active stacks
    echo
    echo "You have the following active stacks:"
    print_stacks | sort | column -t -N "ID,PHOENIXD,LNBITS"

    PHOENIXD_DOMAIN=$( print_stacks | awk 'print $2' )
    LNBITS_DOMAIN=$( print_stacks | awk 'print $3' )
    
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

if [[ $( print_stacks | wc -l ) -gt 0 ]]; then
    echo "You have the following active stacks:"
    print_stacks | sort | column -t -N "ID,PHOENIXD,LNBITS"
    echo
fi


case $1 in
  ""|"add")
    # Request configuration data from the user
    echo ">>>Please provide needed configuration infos<<<"
    echo
    read -p "Enter the domain for Phoenixd API (e.g., api.yourdomain.com): " PHOENIXD_DOMAIN
    read -p "Enter the domain for LNbits (e.g., lnbits.yourdomain.com): " LNBITS_DOMAIN
    read -p "Do you want real Letsencrypt certificates to be issued? (y/N): " letscertificates
    read -p "Do you want LNBits to use PostgreSQL? (y/N): " postgresyesno
    
    if [[ ! $letscertificates =~ ^[Yy]$ ]]; then
        letscertificates="n"
    fi
    if [[ ! $postgresyesno =~ ^[Yy]$ ]]; then
        postgresyesno="n"
    fi
    echo
    echo "A new $STACK is going to be added with the following specs:"
    echo "$SID $PHOENIXD_DOMAIN $LNBITS_DOMAIN $letscertificates $postgresyesno" | column -t -N "ID,PHOENIXD,LNBITS,LETSENCRYPT,POSTGRES"
    read -p "Do you want to continue? (y/N): " addyesno
    echo

    if [[ ! $addyesno =~ ^[Yy]$ ]]; then
        exit 0
    fi

    trap "exit 128" SIGINT
    trap "exit 129" SIGQUIT
    trap "exit 143" SIGTERM
    trap init_trap EXIT

    # Copy example files
    mkdir -p nginx $STACK
    if [[ ! -f docker-compose.yml ]]; then
        cp docker-compose.yml.example docker-compose.yml 
    fi

    cp default.conf.example nginx/$STACK.conf
    if [[ $postgresyesno =~ ^[Yy]$ ]]; then
    	cp docker-compose.yml.stack.example $STACK/docker-compose.yml
    	cp .env.example $STACK/.env
    else
    	cp docker-compose.yml.stack.sqlite.example $STACK/docker-compose.yml
    	cp .env.sqlite.example $STACK/.env
    fi

    echo "docker-compose.yml, nginx/$STACK.conf and $STACK/.env files set up."
    echo

    # Generate certificates
    if [[ ! $letscertificates =~ ^[Yy]$ ]]; then
           echo "Issuing selfsigned certificates on local host..."
    	generate_certificates $PHOENIXD_DOMAIN $LNBITS_DOMAIN
    else
           echo "Issuing Letsencrypt certificates on local host..."
    	generate_certificates_certbot $PHOENIXD_DOMAIN $LNBITS_DOMAIN
    fi
    
    # Generate password for Postgres
    POSTGRES_PASSWORD=$(generate_password)

    # Update the .env file
    echo "Updating the $STACK/.env file..."

    # Remove or comment out unnecessary variables
    sed -i '/^LNBITS_BACKEND_WALLET_CLASS=/d' $STACK/.env
    sed -i '/^PHOENIXD_API_ENDPOINT=/d' $STACK/.env
    sed -i '/^PHOENIXD_API_PASSWORD=/d' $STACK/.env
    sed -i '/^LNBITS_DATABASE_URL=/d' $STACK/.env
    sed -i '/^LNBITS_SITE_TITLE=/d' $STACK/.env
    sed -i '/^LNBITS_SITE_TAGLINE=/d' $STACK/.env
    sed -i '/^LNBITS_SITE_DESCRIPTION=/d' $STACK/.env

    # Add or update necessary variables
    update_env "LNBITS_BACKEND_WALLET_CLASS" "PhoenixdWallet"
    update_env "PHOENIXD_API_ENDPOINT" "http://phoenixd-$SID:9740/"
    
    # If no postgresql, there is no LNBITS_DATABASE_URL to configure in .env file
    if [[ $postgresyesno =~ ^[Yy]$ ]]; then
    	update_env "LNBITS_DATABASE_URL" "postgres://postgres:$POSTGRES_PASSWORD@postgres-$SID:5432/lnbits"
    fi
    
    update_env "LNBITS_SITE_TITLE" "$LNBITS_DOMAIN"
    update_env "LNBITS_SITE_TAGLINE" "\"free and open-source lightning wallet\""
    update_env "LNBITS_SITE_DESCRIPTION" "\"The world's most powerful suite of bitcoin tools. Run for yourself, for others, or as part of a stack.\""
    
    # Add a comment for PHOENIXD_API_PASSWORD
    echo "# PHOENIXD_API_PASSWORD will be set after the first run" >> $STACK/.env
    
    echo "$STACK/.env file successfully updated."

    # Update the docker-compose.yml stack file
    echo "Updating the $STACK/docker-compose.yml file..."
    sed -i "s/POSTGRES_PASSWORD: XXXX/POSTGRES_PASSWORD: $POSTGRES_PASSWORD/" $STACK/docker-compose.yml
    sed -i "s/^\( *phoenixd\):/\1-$SID:/" $STACK/docker-compose.yml
    sed -i "s/^\( *lnbits\):/\1-$SID:/" $STACK/docker-compose.yml
    sed -i "s/^\( *postgres\):/\1-$SID:/" $STACK/docker-compose.yml
    sed -i "s/^\( *container_name: .*\)$/\1-$SID/" $STACK/docker-compose.yml
    
    echo "$STACK/docker-compose.yml file successfully updated."

    # Update the default.conf file
    echo "Updating the nginx/$STACK.conf file..."
    sed -i "s/server_name n1\.yourdomain\.com;/server_name $PHOENIXD_DOMAIN;/" nginx/$STACK.conf
    sed -i "s/server_name lb1\.yourdomain\.com;/server_name $LNBITS_DOMAIN;/" nginx/$STACK.conf
    sed -i "s|ssl_certificate /etc/letsencrypt/live/n1\.yourdomain\.com/|ssl_certificate /etc/letsencrypt/live/$PHOENIXD_DOMAIN/|" nginx/$STACK.conf
    sed -i "s|ssl_certificate_key /etc/letsencrypt/live/n1\.yourdomain\.com/|ssl_certificate_key /etc/letsencrypt/live/$PHOENIXD_DOMAIN/|" nginx/$STACK.conf
    sed -i "s|ssl_certificate /etc/letsencrypt/live/lb1\.yourdomain\.com/|ssl_certificate /etc/letsencrypt/live/$LNBITS_DOMAIN/|" nginx/$STACK.conf
    sed -i "s|ssl_certificate_key /etc/letsencrypt/live/lb1\.yourdomain\.com/|ssl_certificate_key /etc/letsencrypt/live/$LNBITS_DOMAIN/|" nginx/$STACK.conf
    sed -i "s|\(http://phoenixd\)|\1-$SID|" nginx/$STACK.conf
    sed -i "s|\(http://lnbits\)|\1-$SID|" nginx/$STACK.conf
    echo "nginx/$STACK.conf file successfully updated."

    # Link to docker-compose file
    echo "Linking $STACK to docker-compose.yml file"
    sed -i "/^services:/i \ \ - $STACK/docker-compose.yml" docker-compose.yml

    echo "Configuration completed. "
    echo "Certificates have been generated for $PHOENIXD_DOMAIN and $LNBITS_DOMAIN"

    # Start the Postgres container
    if [[ $postgresyesno =~ ^[Yy]$ ]]; then
    	echo "Starting the Postgres container..."
    	docker compose up -d postgres-$SID
    
    	# Wait for Postgres to be ready
    	echo "Waiting for Postgres to be ready..."
    	until docker compose exec postgres-$SID pg_isready
    	do
    	  echo "Postgres is not ready yet. Waiting..."
    	  sleep 2
    	done
    	echo "Postgres is ready."
    fi

    # Start the Phoenixd container
    echo "Starting the Phoenixd container..."
    docker compose up -d phoenixd-$SID
    wait_for_container lightstack-phoenixd-$SID
    
    echo "Waiting phoenixd to write stuffs..."
    sleep 20

    # Start the LNbits container
    echo "Starting the LNbits container..."
    docker compose up -d lnbits-$SID
    wait_for_container lightstack-lnbits-$SID

    # Start the Nginx container
    echo "Starting the Nginx container..."
    if docker ps | grep lightstack-nginx; then
        docker compose restart nginx
    else
        docker compose up -d nginx
    fi

    wait_for_container lightstack-nginx
    
    echo "All containers have been started."

    # Wait a bit to allow containers to fully initialize
    echo "Waiting 30 seconds to allow for complete initialization..."
    sleep 30
    
    # Stop stack containers
    echo "Stopping $STACK containers..."
    docker rm -f $( docker ps | grep -E "lightstack-(lnbits|phoenixd|postgres)-$SID" | awk '{print $1}' )
    docker compose down nginx
    
    echo "$STACK containers have been stopped."

    # Configure phoenix.conf and update .env
    echo "Configuring $STACK/phoenix.conf and updating $STACK/.env..."
    
    # Use the relative path to the current directory
    PHOENIX_CONF="$STACK/data/phoenix.conf"
    
    if [ ! -f "$PHOENIX_CONF" ]; then
        echo "ERROR: $PHOENIX_CONF file not found" >&2
        echo "Setup aborted!"
        exit 1
    fi

    # Allow phoenixd to listen from 0.0.0.0 
    if ! grep -q "^http-bind-ip=0.0.0.0" "$PHOENIX_CONF"; then
        sed -i '1ihttp-bind-ip=0.0.0.0' "$PHOENIX_CONF"
        echo "http-bind-ip=0.0.0.0 added to $PHOENIX_CONF"
    else
        echo "http-bind-ip=0.0.0.0 already present in $PHOENIX_CONF"
    fi

    # Extract Phoenixd password
    PHOENIXD_PASSWORD=$(grep -oP '(?<=http-password=).*' "$PHOENIX_CONF")
    if [ -n "$PHOENIXD_PASSWORD" ]; then
        echo "Phoenixd password found: $PHOENIXD_PASSWORD"
        update_env "PHOENIXD_API_PASSWORD" "$PHOENIXD_PASSWORD"
        echo "PHOENIXD_API_PASSWORD updated in $STACK/.env file"
    else
        echo "ERROR: Phoenixd password not found in $PHOENIX_CONF" >&2
        echo "Setup aborted!"
        exit 1
    fi

    # Verify the contents of the files
    echo
    echo "Relevant contents of the nginx/$STACK.conf file after update:"
    grep -E "(server_name|ssl_certificate|proxy_pass)" nginx/$STACK.conf | sed 's/^ *//'
    echo
    echo "Relevant contents of the $STACK/.env file after update:"
    grep -E "^(LNBITS_BACKEND_WALLET_CLASS|PHOENIXD_API_ENDPOINT|PHOENIXD_API_PASSWORD|LNBITS_DATABASE_URL|LNBITS_SITE_TITLE|LNBITS_SITE_TAGLINE|LNBITS_SITE_DESCRIPTION)=" $STACK/.env
    echo

    echo "Configuration of phoenix.conf and .env update completed."
    
    echo "Setup completed."
    echo "Postgres password: $POSTGRES_PASSWORD"
    if [[ $postgresyesno =~ ^[Yy]$ ]]; then
    	echo "Phoenixd password: $PHOENIXD_PASSWORD"
    fi
    echo

    # Restart all containers
    echo "Restarting all containers with the new configurations..."
    docker compose up -d

    # Verify active stacks
    echo
    echo "You have the following active stacks:"
    print_stacks | sort | column -t -N "ID,PHOENIXD,LNBITS"
    
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
    ;;

  "clear")
    if [[ $( print_stacks | wc -l ) -gt 0 ]]; then
        echo ">>>This will remove all of your stacks. Data will not be recoverable<<<"
        echo
        read -p "Are you sure you want to continue? (y/N): " clearyesno
        echo

        if [[ $clearyesno =~ ^[Yy]$ ]]; then
            docker compose down
            rm -Rf letsencrypt nginx stack_* docker-compose.yml
            echo "Setup cleared"
        fi
    fi
    ;;

  "del"|"rem")
    if [[ $( print_stacks | wc -l ) -eq 0 ]]; then
        echo "No active stacks found."
        echo "Please, run 'sudo ./init.sh' in order to initialize the system."
        print_help
        exit 0
    fi

    if [[ $( print_stacks | wc -l ) -eq 1 ]]; then
        SID=$( print_stacks | awk '{print $1}' )
    else
        read -p "Which stack ID do you want to delete? " SID
    
        if ! print_stacks | awk '{print $1}' | grep $SID; then
            echo "ERROR: stack $SID not found" >&2
            exit 1
        fi
    fi
    STACK="stack_$SID"

    echo
    echo ">>>This will remove stack $SID. Data will not be recoverable<<<"
    echo
    read -p "Are you sure you want to continue? (y/N): " remyesno

    if [[ ! $remyesno =~ ^[Yy]$ ]]; then
        exit 0
    fi

    # Stop stack containers
    echo "Stopping $STACK containers..."
    if [[ $( print_stacks | wc -l ) -eq 1 ]]; then
        docker compose down
    else
        if docker ps | grep -E "lightstack-(lnbits|phoenixd|postgres)-$SID"; then
            docker rm -f $( docker ps | grep -E "lightstack-(lnbits|phoenixd|postgres)-$SID" | awk '{print $1}' )
        fi
    fi
    echo "$STACK containers have been stopped."

    # Remove data
    echo "Removing $STACK data..."
    if [[ $( print_stacks | wc -l ) -eq 1 ]]; then
        rm -rf letsencrypt nginx $STACK docker-compose.yml
    else
        rm -rf nginx/$STACK.conf rm -rf $STACK
        sed -i "/$STACK/d" docker-compose.yml
    fi
    echo "$STACK data removed."

    # Restart nginx
    if [[ $( print_stacks | wc -l ) -gt 1 ]]; then
        echo "Restarting nginx..."
        docker compose restart nginx
        echo "Nginx restarted."
    fi
    echo "$STACK successfully removed."

    if [[ $( print_stacks | wc -l ) -gt 0 ]]; then
        echo "You have the following active stacks:"
        print_stacks | sort | column -t -N "ID,PHOENIXD,LNBITS"
    fi
    ;;

  "help")
    print_help
    ;;

  *)
    echo "Unsupported command '$1'" >&2
    print_help
    exit 1
    ;;
esac
