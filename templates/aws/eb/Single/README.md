# Supportpal Elasticbeanstalk Single Instance Deployment


## First time setup

Start by renaming:
```shell
cp docker-compose.yml.dist docker-compose.yml

cp .ebextensions/00storage-efs-mountfilesystem.config.dist .ebextensions/00storage-efs-mountfilesystem.config
cp .ebextensions/01storage-docker-createvolumes.config.dist .ebextensions/01storage-docker-createvolumes.config 
cp .ebextensions/instances.config.dist .ebextensions/instances.config 
cp .ebextensions/options.config.dist .ebextensions/options.config 
cp .ebextensions/securitygroup.config.dist .ebextensions/securitygroup.config
cp .ebextensions/vpc.config.dist .ebextensions/vpc.config
```

Copy the gateway configuration from the repository root
```shell
cp -R ../../../../configs/gateway .
```

### 1. Dependencies

To proceed with this deployment, you will need to have AWS EB CLI utility installed. Please follow the following [documentation](https://docs.aws.amazon.com/elasticbeanstalk/latest/dg/eb-cli3-install.html) for more information. 

You also need to create the required AWS resource dependencies in the following [documentation](../dependencies.md)

### 2. Environment

Initiate the environment and choose the desired region:
```shell
$ eb init

Select a default region
1) us-east-1 : US East (N. Virginia)
2) us-west-1 : US West (N. California)
3) us-west-2 : US West (Oregon)
...
```

Select your application name based on your preference:
```shell
Enter Application Name
(default is "Single"): Helpdesk
```

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

Setting up SSH is optional.

### 3. Configuration

* Inside your `02storage-efs-mountfilesystem.config`, update the filesystem id value using the EFS id you created earlier:
```yaml
option_settings:
  aws:elasticbeanstalk:application:environment:
    FILE_SYSTEM_ID: fs-XXXXX
```

* Inside your `options.config`, update the `HOST` environment variable.
```yaml
option_settings:
    aws:elasticbeanstalk:application:environment:
        HOST: example.com
```  

* Inside your `securitygroup.config`, add the security groups you created earlier (web, internal, ssh):
```yaml
option_settings:
  aws:autoscaling:launchconfiguration:
    SecurityGroups: sg-XXXX, g-YYYY, g-ZZZZ
```

* Inside your `vpc.config`, add the id of your VPC, and add at least 3 availability zones.
```yaml
option_settings:
aws:ec2:vpc:
VPCId: vpc-XXXXX
Subnets: subnet-XXXX, subnet-YYYY, subnet-ZZZZ
```
> Noting that all your configurations should share the same VPC and should be reachable on the same availability zones.


### 4. Environment Creation

```shell
eb create production --single
```

Once you see that the environment is deployed successfully, you can proceed to setup the helpdesk.

### 5. Enabling HTTPS

By default, the software will run on HTTP using port 80. However, we recommend using HTTPS for added security. to enable HTTPS, we provide an integration with letsencrypt, you can enable it by using the following:

* rename `docker-compose.override.yml.dist` to `docker-compose.override.yml`
* rename `.ebextensions/ssl.config.dist` to `.ebextensions/ssl.config`
* Inside `ebextensions/options.config` add a new environment variable:
```dotenv
DOMAIN_NAME: example.com
```
* copy `cp ../../configs/letsencrypt/init-letsencrypt.sh .` then update the following parameters:
```shell
domains=(example.com www.example.com) #your domain name, the top level domain should match the env variable set in the previous step
email="" # Adding a valid address is strongly recommended
staging=0 # Set to 1 if you're testing your setup to avoid hitting request limits
```


Enabling SSL with your own certificates might require special configuration based on the CA and cipher. You will need to make updates to the Nginx files by providing a directory that includes the keys, then map the keys so they can be read by the nginx container. We can't provide specific details as the process might not be the same across all certificates.

### 6. Helpdesk setup

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
