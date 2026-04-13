# Set Up Docker and Git

We'll use lots of tools in the course and they each have their own dependencies and configuration. To simplify we'll use Docker containers to run all the components, so you don't need to install a ton of software.

> You don't need any Docker experience for this course, everything will be scripted out for you.

Use the `provision-lab-instances.sh` script to provision the EC2 instance.
Open the script and make the required changes. You also need to install the `aws cli` in your machine for configuring the aws credentials from the IAM page.

```bash
# after installing aws cli run:
aws configure
```

This script will create an EC2 instance and also install all the required tools required to run this lab.

```bash
bash setup/provision-lab-instances.sh
```

## Check your setup

When you have Git and Docker installed you should be able to run these commands and get some output:

```
git --version
```

Then run:

```
docker version
```
> Make sure you see two sets of results: `Client:` and `Server:`

And then:

```
docker compose version
```
