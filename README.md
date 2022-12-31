<div align="center">


<img src="https://user-images.githubusercontent.com/14128371/210153083-55fc62ad-72be-4600-be05-1e5535fedd5d.png" align="center" width="144px" height="144px"/>

## Pork3s
The k3s cluster of Pork Chop

</div>

---

## Overview

In my day to day work, I'm responsible for the administration, deployment, and monitoring of many k8s clusters. I realized though that my homelab is getting dated, and is essentially just one large docker host that is responsible for everything from storage, to compute, to networking, to home automation. That's one large single point of failure, so I guess it's time to bring my work into my homelab as well! (What's the saying? The mechanic's car is always broken down.)

This repo will track the iterative process I'll be using to first configure my network, deploy the storage server, deploy the k3s cluster, and eventually deploy all my home applications. I'll be HEAVILY utilizing the awesome work that [onedr0p](https://github.com/onedr0p/home-ops) has already put forward, but with tweaks and changes for my own needs along the way.

---

## Prereqs
### 💻 Local Setup

I'm using [Task](https://taskfile.dev/) to setup the necessary packages and applications on my local machine for interacting and deploying the cluster.

1. Install [go-task](https://github.com/go-task/task) via Brew

    ```sh
    brew install go-task/tap/go-task
    ```

2. Install workstation dependencies via Brew

    ```sh
    task init
    ```

This installs all of the packages listed in `Taskfile.yml`. 

### ⚠️ pre-commit
[pre-commit](https://pre-commit.com/) runs checks on your code before commiting them to git so you can fix issues before it gets up to your repo. 

1. Enable Pre-Commit

    ```sh
    task precommit:init
    ```

2. Update Pre-Commit, though it will occasionally make mistakes, so verify its results.

    ```sh
    task precommit:update
    ```