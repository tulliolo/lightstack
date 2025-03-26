# Full Phoenixd Stack

 Just run your own self-custodial cloud Lightning node on your VPS, from your domain name, with this stack. You immediately get a LNBits instance on your own node and the phoenixd endpoint available on a SSL connection.

 A multistack feature has been added and makes possible to add multiple stacks to the same VPS, served simultaneously. A Web UI has been integrated as well

## Installation

### Get the repo

```
cd ~
git clone https://github.com/massmux/lightstack.git
cd lightstack
```

### Choose domain and cnames

choose two subdomains on your domain, where you have the DNS management. They must point the A record to the host server IP and this must be already propagated when you are going to invoke initialization script. In my example they are

- n1.yourdomain.com
- lb1.yourdomain.com

n1 will be the endpoint for phoenixd APIs
lb1 will be the lnbits install

### Initialize (command line interface)

You can install the stack either using the command line interface of by the Web UI. If you start by using command line, just always go on with that.

```
cd lightstack
./init.sh

```

The interactive init script makes possible to choose beween using PostgreSQL or SQLite as database support, and choose self-signed certificates (for testing purposes) or Letsencrypt ones. You will be asked during install.

PostgreSQL is better when thinking to large amount of users installs.

In case you need to start inizialization from the beginning, you need to clear existing configuration (if the case) by issuing:

```
./init.sh clear
```

Please note that this will clear all data, configuration files and database in existing directory. If you had funds in that node, you will loose them all, so be careful and check it before

 Help shows usage and active stacks. Stacks can be also removed by the below commands:

```
dev@lightstack:~/lightstack$ sudo ./init.sh help

You have the following active stacks:
ID  PHOENIXD            LNBITS
1   n1.yourdomain.com   lb1.yourdomain.com
2   n2.yourdomain.com   lb2.yourdomain.com


Usage: init.sh [command]
  command:
    add [DEFAULT]:  to init a new system and/or add a new stack
    clear:          to remove all stacks
    del|rem:        to remove a stack
    help:           to show this message
```

### Install Web Interface

A WEB UI has been added to manage stacks. This is for now installed into the host system. Installing the web UI does not interfere with command line interface. So you can decide to use it or not based on your skills and preferences.

To install the web UI (interactive mode), run:

```
cd ~
git clone https://github.com/massmux/lightstack.git
cd lightstack
sudo ./gui-install-interactive.sh
```

This command will set up the web-based management interface for your LightStack. The interface provides an easy way to monitor and manage your node.

Otherwise you can prefer non-interactive mode. In this case, set up your details into the kickstart.sh file with the environment variables, then run it.

Please be always sure that all your domains and subdomains point to the IP of the VPS as DNS A record (not cname).


### Access

Access LNBITS instance at:

- https://lb1.yourdomain.com

Access phoenixd API endpoint with:

- https://n1.yourdomain.com
- http password: provided in phoenix.conf file

in case you want to tune your configuration you can always setup the .env file as you prefer.

### VPS

VPS provided and tested by https://denali.eu
