# SupportPal Installation Templates

This repository contains templates to get started using SupportPal.

## Docker Compose

This [template](https://docs.supportpal.com/current/Deploy+on+Docker) relies on docker-compose to manage the helpdesk software deployment. A typical use case for this template would be a standalone server.

## AWS Elastic Beanstalk
### Preview / Testing

This [directory](templates/aws/eb/Preview) contains a [template](templates/aws/eb/Preview/README.md) which is intended for exploring product functionality and testing purposes. It couples the lifecycle of your compute and data resources to your Elastic Beanstalk environment. In other words, when the environment is destroyed so are all your resources. AWS recommends to decouple data services to prevent any accidental destruction of data.

If you want a production-ready deployment, we recommend using either Single or High Availability deployments.

### Single Server

This [directory](templates/aws/eb/Single) contains a production ready [template](templates/aws/eb/Single/README.md) intended for a single instance deployment without a load balancer.

### High Availability

This [directory](templates/aws/eb/HA) contains a production ready [template](templates/aws/eb/HA/README.md) intended for high availability deployments.

## Linux

A [convenience script](https://docs.supportpal.com/current/Deploy+on+Linux) to install and configure system on supported Linux operating systems.
