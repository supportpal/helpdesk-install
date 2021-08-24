# SupportPal Elastic Beanstalk High Availability Deployment

----

## Install SupportPal

Copy nginx configuration files from root repository.
```shell
cp -R ../../../../configs/gateway web/
cp -R ../../../../configs/gateway cron/
cp -R ../../../../configs/gateway ws/
```

Rename the following files:

```shell
cp web/docker-compose.yml.dist web/docker-compose.yml
cp cron/docker-compose.yml.dist cron/docker-compose.yml
cp ws/docker-compose.yml.dist ws/docker-compose.yml

cp .ebextensions/00storage-efs-mountfilesystem.config.dist .ebextensions/00storage-efs-mountfilesystem.config
cp .ebextensions/01storage-docker-createvolumes.config.dist .ebextensions/01storage-docker-createvolumes.config
cp .ebextensions/instances.config.dist .ebextensions/instances.config
cp .ebextensions/options.config.dist .ebextensions/options.config
cp .ebextensions/securitygroup.config.dist .ebextensions/securitygroup.config
cp .ebextensions/vpc.config.dist .ebextensions/vpc.config

cp web/.ebextensions/loadbalancer.config.dist web/.ebextensions/loadbalancer.config
```


### 1. Dependencies

To proceed with this deployment, you will need to have AWS EB CLI utility installed. Please follow the following [documentation](https://docs.aws.amazon.com/elasticbeanstalk/latest/dg/eb-cli3-install.html) for more information.

You also need to create the required AWS resource dependencies in the following [documentation](../dependencies.md)


### 2. Modules

Initiate the environment and choose the desired region:
```shell
$ eb init --modules web cron ws

Select a default region
1) us-east-1 : US East (N. Virginia)
2) us-west-1 : US West (N. California)
3) us-west-2 : US West (Oregon)
...
```

Select your application name based on your preference:
```shell
Enter Application Name
(default is "HA"): Helpdesk
```

Proceed with the same steps for both modules.

Select Docker as your application platform:
```shell
Select a platform.
1) .NET Core on Linux
2) .NET on Windows Server
3) Docker
4) GlassFish
5) Go
6) Java
7) Node.js
8) PHP
9) Packer
10) Python
11) Ruby
12) Tomcat
(make a selection): 3
```

Select Docker on AMI2 as platform branch:
```shell
Select a platform branch.
1) Docker running on 64bit Amazon Linux 2
2) Multi-container Docker running on 64bit Amazon Linux
3) Docker running on 64bit Amazon Linux
(default is 1):  1
```

Choose the same options for each module.

### 3. Configuration

Change the .ebextensions files inside `elasticbeanstalk/HA/.ebextensions/` as follows:

* Inside your `00storage-efs-mountfilesystem.config`, update the filesystem id value using the EFS id you created earlier:
```yaml
option_settings:
  aws:elasticbeanstalk:application:environment:
    FILE_SYSTEM_ID: fs-XXXXX
```
* Inside your `options.config`, update the `CACHE_SERVICE_NAME` value to the ElastiCache instance URL, and `HOST`.
```yaml
option_settings:
    aws:elasticbeanstalk:application:environment:
        CACHE_SERVICE_NAME: REDIS_AWS_ENDPOINT
        HOST: example.com
```  


* Inside your `securitygroup.config`, add the security groups you created earlier (web, internal, ssh):
```yaml
option_settings:
  aws:autoscaling:launchconfiguration:
    SecurityGroups: sg-XXXX, g-YYYY, g-ZZZZ
```

* Inside your `vpc.config`, add the id of your VPC, and add at least 3 availability zones. Make sure that the last subnet zone is the same of your EFS filesystem.  
```yaml
option_settings:
aws:ec2:vpc:
VPCId: vpc-XXXXX
Subnets: subnet-XXXX, subnet-YYYY, subnet-ZZZZ
```

> Noting that all your configurations should share the same VPC and should be reachable on the same availability zones.

* Once you update all the files, copy them over to the modules directories.
```yaml
cp .ebextensions/*.config web/.ebextensions/
cp .ebextensions/*.config cron/.ebextensions/
cp .ebextensions/*.config ws/.ebextensions/
```

### 4. Web

Navigate to the web directory, and create the environment

```shell
cd web
eb create web-production
```

### 5. Helpdesk setup

To setup your helpdesk, you can either SSH to your environment, or choose to setup the helpdesk using the graphical interface.

#### Web interface
* Make sure you select your desired region on AWS web panel
* Locate your EBS Environment URL on [EBS Environments](https://console.aws.amazon.com/elasticbeanstalk/home#/environments)
* Navigate to the URL

#### SSH
* Make sure you select your desired region on AWS web panel
* Locate your EC2 instance public DNS/IP on [EC2 dashboard](https://console.aws.amazon.com/ec2/v2/home#Instances:)
* SSH to your instance and execute the setup command
```shell
ssh-add ~/.ssh/your_ssh_key_pair

ssh ec2-user@your-ec2-instance-dns-or-public-ip
sudo docker exec -it supportpal su www-data -s /usr/local/bin/php artisan app:install
```

### 6. CRON

Once you finish setting up your web environment, navigate to the CRON directory and create the environment
```shell
cd ../cron
eb create cron-production --single
```

### 7. Web Sockets

Navigate to the `ws` directory and create the environment:
```shell
cd ../ws
eb create ws-production --single
```

### 8. Configure HTTPS

By default, the software will run on HTTP using port 80. However, we recommend using HTTPS for added security. to enable HTTPS, we suggest that you do so at the level of the load balancer.  To do that please check the [AWS documentation](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/create-https-listener.html).

----

# Configuring PHP

The default PHP config can be customised by copying configuration files into the containers.

1. Browse to the `web` directory
2. Create a `php/custom.ini` file
3. Add your PHP configuration to the file
4. Update the `volumes` definition for the `supportpal` container in `docker-compose.yml`:
   ```
   - ./php/custom.ini:/usr/local/etc/php/conf.d/9999-custom-config.ini
   ```
   You can change the `9999` in the filename to control the priority of the configuration.
   `9999` means it is loaded last.
5. If necessary, repeat steps 1 - 4 for the `cron` directory.
6. Redeploy the application
   ```bash
   eb deploy production
   ```

----

## Customizing SupportPal

To [customize](https://docs.supportpal.com/current/Customisation) SupportPal:
1. Place your customizations in the relevant `customizations` directory. 
   
   For example, `customizations/languages/de` would be used for German translation files.
2. Copy the changes to both cron and web deployments:
```bash
cp -R customization web/
cp -R customization cron/
```
3. Redeploy the application
```bash
eb deploy web-production
eb deploy cron-production
```

----

## Upgrade SupportPal

Before upgrading, we recommend that you take a full backup of all your files and configurations.

* Make sure that you backup your EFS filesystem on AWS (all files and directories in your `/supportpal` directory)
* Make sure that you have a recent backup of your RDS database

To upgrade to a new SupportPal version:
1. Open `.ebextensions/options.config`
2. Change the application version
```
APP_VERSION: 3.3.1
```
3. Redeploy the application
```bash
eb deploy web-production
eb deploy cron-production
```

----

## Debugging

If you have any problems, read the log files:
```bash
eb logs web-production
eb logs cron-production
```
