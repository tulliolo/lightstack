#!/bin/bash

# Update or add a variable in the .env file
#

# Function to generate a random password
generate_password() {
    openssl rand -base64 12 | tr -d "=+/" | cut -c1-16
}

update_env() {
    local key=$1
    local value=$2
    local file="$STACK/.env"
    if grep -q "^$key=" "$file"; then
        sed -i "s|^$key=.*|$key=$value|" "$file"
    else
        echo "$key=$value" >> "$file"
    fi
}

# Wait for a container to be ready
wait_for_container() {
    echo "Waiting for $1 to be ready..."
    until [ "`docker inspect --format=\"{{.State.Running}}\" $1`"=="true" ]; do
        sleep 1;
    done;
    sleep 2;
    echo "$1 is ready."
}

# Generate self-signed certificates
generate_certificates() {
    local phoenixd_domain=$1
    local lnbits_domain=$2
    local cert_dir="letsencrypt/live"

    echo "Generating self-signed certificates for testing..."

    # Create necessary directories
    mkdir -p "$cert_dir/$phoenixd_domain"
    mkdir -p "$cert_dir/$lnbits_domain"

    # Generate certificates for Phoenixd domain
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "$cert_dir/$phoenixd_domain/privkey.pem" \
        -out "$cert_dir/$phoenixd_domain/fullchain.pem" \
        -subj "/CN=$phoenixd_domain" 2>/dev/null

    if [ $? -eq 0 ]; then
        echo "Certificates for $phoenixd_domain generated successfully."
    else
        echo "An error occurred while generating certificates for $phoenixd_domain."
        exit 1
    fi

    # Generate certificates for LNbits domain
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "$cert_dir/$lnbits_domain/privkey.pem" \
        -out "$cert_dir/$lnbits_domain/fullchain.pem" \
        -subj "/CN=$lnbits_domain" 2>/dev/null

    if [ $? -eq 0 ]; then
        echo "Certificates for $lnbits_domain generated successfully."
    else
        echo "An error occurred while generating certificates for $lnbits_domain."
        exit 1
    fi

    echo "Self-signed certificates generated successfully for testing."
}

# Generate Letsencrypt certificates
generate_certificates_certbot() {
    local phoenixd_domain=$1
    local lnbits_domain=$2

    echo "Generating valid certificates using Certbot..."

    # Prompt for email address
    read -p "Enter an email address for important account notifications: " cert_email

    # Prompt for Terms of Service agreement
    echo "Please read the Let's Encrypt Terms of Service at https://letsencrypt.org/documents/LE-SA-v1.2-November-15-2017.pdf"
    read -p "Do you agree to the Let's Encrypt Terms of Service? (y/n): " tos_agreement
    if [[ ! $tos_agreement =~ ^[Yy]$ ]]; then
        echo "You must agree to the Terms of Service to continue."
        exit 1
    fi

    # Generate certificate for Phoenixd domain
    echo "Generating certificate for $phoenixd_domain"
    sudo certbot certonly --standalone -d $phoenixd_domain --email $cert_email --agree-tos

    if [ $? -eq 0 ]; then
        echo "Certificate for $phoenixd_domain generated successfully."
    else
        echo "An error occurred while generating certificate for $phoenixd_domain."
        exit 1
    fi

    # Generate certificate for LNbits domain
    echo "Generating certificate for $lnbits_domain"
    sudo certbot certonly --standalone -d $lnbits_domain --email $cert_email --agree-tos

    if [ $? -eq 0 ]; then
        echo "Certificate for $lnbits_domain generated successfully."
    else
        echo "An error occurred while generating certificate for $lnbits_domain."
        exit 1
    fi

    echo "Valid certificates generated successfully using Certbot."
    echo "Copying letsencrypt dir..."
    sudo cp -R /etc/letsencrypt .
}

# calculate the next stack id
generate_stack_id() {
    local sid=$( find ./ -type d -name "stack_*" | sed 's/^.*stack_//' | sort -n | tail -1 )
    if [[ -n $sid ]]
    then
        echo $(( $sid + 1 ))
    else
        echo 1
    fi
}

# print active stacks
print_stacks() {
    for sid in $( find ./ -type d -name "stack_*" | sed 's/^.*stack_//' )
    do
        local domains=$(grep "server_name" "nginx/stack_$sid.conf" | sed -e 's/^.*server_name *//' -e 's/;//' | tr '\n' ' ')
        echo "$sid $domains"
    done
}

# print script help
print_help(){
    echo
    echo "Usage: init.sh [command]"
    echo "  command:"
    echo "    add [DEFAULT]:  to init a new system and/or add a new stack"
    echo "    clear:          to remove all stacks"
    echo "    del|rem:        to remove a stack"
    echo "    help:           to show this message"
}

# Restore on error during migration
migration_trap() {
    local exit_code=$?

    trap - SIGINT SIGQUIT SIGTERM

    if [[ $exit_code -eq 0 ]]; then
        rm -rf .backup
    else
        echo
        echo "***An error occurred during the migration process***"
        echo "Your previous stack will be restored."
        echo
        
        if [[ -f docker-compose.yml ]]; then
            # Stop all containers
            echo "Stopping all containers..."
            docker compose down
            echo "All containers have been stopped."
        fi

        # Restore configurations and data
        echo "Restoring configurations and data"
        rm -rf nginx $STACK docker-compose.yml
        cd .backup
        mv -t ../ data lnbitsdata .env default.conf docker-compose.yml
        if [[ -d pgdata ]]; then
            mv pgdata ../
        fi
        if [[ -d pgtmp ]]; then
            mv pgtmp ../
        fi
        cd ../
        rm -rf .backup
        echo "Restore completed."

        # Start all containers
        echo "Starting all containers..."
        docker compose up -d
        echo "All containers have been started."
        echo

        echo "***Migration failed with code $exit_code***"
        echo "Your previous system was restored and is now ready for use."
        echo "You can save logs and notify the issue at https://github.com/massmux/lightstack/issues."
    fi

    exit $exit_code
}

# Restore on error during init/add
init_trap() {
    local exit_code=$?

    trap - SIGINT SIGQUIT SIGTERM
    
    if [[ ! $exit_code -eq 0 ]]; then
        echo
        echo "***An error occurred during the init process***"
        echo "Cleaning up..."

        # Stop containers
        echo "Stopping $STACK containers..."
        if docker ps | grep -E "lightstack-(lnbits|phoenixd|postgres)-$SID"; then
            docker rm -f $( docker ps | grep -E "lightstack-(lnbits|phoenixd|postgres)-$SID" | awk '{print $1}' )
        fi
        docker compose down nginx
        echo "$STACK containers have been stopped."
        
        echo "Removing $STACK data..."
        rm -rf $STACK nginx/$STACK.conf
        sed -i "/$STACK/d" docker-compose.yml
        if [[ $( print_stacks | wc -l ) -eq 0 ]]; then
            rm -rf letsencrypt nginx docker-compose.yml
        fi
        echo "$STACK data successfully removed."

        if [[ $( print_stacks | wc -l ) -gt 0 ]]; then
            # Restarting nginx
            echo "Restarting nginx container..."
            docker compose up -d
            echo "nginx container restarted"
        fi
        
        echo "Cleanup completed."
        echo
        echo "***Init failed with code $exit_code***"
        echo "You can save logs and notify the issue at https://github.com/massmux/lightstack/issues."
    fi

    exit $exit_code
}

## Functions section end.

