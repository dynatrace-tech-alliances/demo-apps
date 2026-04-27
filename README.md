# Overview

Below are a few simple guides to add an application for monitoring.

* [EasyTrade](https://github.com/Dynatrace/easytrade/tree/main) is demo application of a ficticious stock broking application to allow users to buy and sell some stocks.  The project consisting of many small services that connect to each other for purposes of demoing Dynatrace monitoring. It can be deployed using Helm Charts to K8s or using Docker Compose.
  
> **Note**
> These guides are not officially supported by Dynatrace

## EasyTrade :: Docker Compose

### Step 1: Provision VM

The below guide is for AWS EC2 instance, but it can be adapted
* Linux OS : `Ubuntu Server 24.04 LTS (HVM), SSD Volume - Architecture 64-bit (x86)`
* Instance Type = `r5.xlarge` (4vCPU 32 GiB Memory)
* You existing or make new PEM file
* Disk = `60 GB`
* Ports `80 and 22`

**These other steps will require to be SSH's into the VM, so do that now.**

### Step 2: Install Docker

Docker is not likely installed by this image by default, so run these commands specified in the [Docker installation guide](https://docs.docker.com/engine/install/ubuntu/#install-using-the-repository).

Once you have run the installation commands, verify Docker is running and docker compose is available anytime with:

```
# verify running
sudo systemctl status docker

# docker commpose list project, should return empty list
sudo docker compose ls
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

2. Run Docker Compose

```
cd easytrade
sudo docker compose up -d
```

3. Verify all containers up.  

It will take a few minutes to download images and start containers from the previous command, but these commands can be run to check on them

```
# overall status of project
sudo docker compose ls

# list out containers
sudo docker compose ps
```

### Step 5: Open the Web UI

In a browser, just open the UI by going to the public IP for the VM using `http`, for example `http://3.92.20.244/`

### Step 6: Verify services and traces in Dynatrace

The EasyTrade application has a small, load generator service that sends continuous traffic to the application.  So to see this activity, within Dynatrace open search and search for: `services` and status and then for a service open the `distributed traces`

### Step 7: Enable problems and more

Within the feature flag page of the demo app (choose the flag icon on the top of the home page), you can adjust problem patterns on and off.  Problems may take a few minutes to appear, but they will show up in Dynatrace within the Problems app that you can find by searching for `problems` in the search menu.

Also refer to the [EasyTrade README](https://github.com/Dynatrace/easytrade/tree/main#where-to-start) for more detail on the UI, how to login, and feature flag details.



