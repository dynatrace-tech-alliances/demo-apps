# Overview

Below are a few simple guides to add an application for monitoring.

> **Note**
> These guides are not officially supported by Dynatrace

## EasyTrade on Docker

### Step 1: Provision VM

The below guide is for AWS EC2 instance, but it can be adapted
* Linux OS : `Ubuntu Server 24.04 LTS (HVM), SSD Volume - Architecture 64-bit (x86)`
* Instance Type = `t3.xlarge` (4vCPU 16 GiB Memory)
* You existing or make new PEM file
* Disk = `60 GB`
* Ports `80 and 22`

**These other steps will require to be SSH's into the VM, so do that now.**

### Step 2: Install Docker Compose

Docker is installed by on this image by default, but docker compose it not. So run these commands:

```bash
# install
DOCKER_CONFIG=${DOCKER_CONFIG:-$HOME/.docker}
mkdir -p $DOCKER_CONFIG/cli-plugins
curl -SL https://github.com/docker/compose/releases/download/v5.1.2/docker-compose-linux-x86_64 -o $DOCKER_CONFIG/cli-plugins/docker-compose
chmod +x $DOCKER_CONFIG/cli-plugins/docker-compose

# verify
docker compose version
```

### Step 3: Install OneAgent

1. Install the Dynatrace OneAgent on the VM.  To do that:
* log into Dynatrace 
* Open search and search for: `deploy oneagent`

2. Within the `Deploy OneAgent` page choose `Linux` and then:
* Make a token and save to safe place for you only see this once
* `x86/64`
* `Full Stack`
* Copy and run the download and install shell scripts in the VM

3. Once installation is complete, verify within Dynatrace by:
* Opening the search
* Search for: `infrastructure & operations`
* Review that the VM appears and is collecting host metrics.

### Step 4: Clone Demo repo and start Docker Compose

1. In the VM, run this command to clone the EasyTrade repo

```
git clone https://github.com/Dynatrace/easytrade.git
```

2. run Docker Compose

```
cd easytrade
docker compose up -d
```

3. Verify all containers up.  

```
docker compose up -d
```

### Step 5: Open the Web UI

In a browser, just open the UI by going to the public IP for the VM using `http`, for example `http://3.92.20.244/`

### Step 6: Verify services and traces in Dynatrace

The EasyTrade application has a small, load generator service that sends continuous traffic to the application.  So to see this activity, within Dynatrace open search and search for: `services` and status and then for a service open the `distributed traces`

### Step 7: Enable problems and more

Within the feature flag page of the demo app (choose the flag icon on the top of the home page), you can adjust problem patterns on and off.  Problems may take a few minutes to appear, but they will show up in Dynatrace within the Problems app that you can find by searching for `problems` in the search menu.

Also refer to the [EasyTrade README](https://github.com/Dynatrace/easytrade/tree/main#where-to-start) for more detail on the UI, how to login, and feature flag details.



