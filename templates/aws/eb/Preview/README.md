# Preview Deployment

> :warning: **Intended for testing purposes only**:
>
> This template couples the lifecycle of your compute and data resources to your Elastic Beanstalk environment.
> In other words, when the environment is destroyed so are all your resources.
> AWS recommends to decouple data services to prevent any accidental destruction of data.


## Install SupportPal

To proceed with this deployment, you will need to have AWS EB CLI utility installed. Please follow the following [documentation](https://docs.aws.amazon.com/elasticbeanstalk/latest/dg/eb-cli3-install.html) for more information.

Start by renaming:
```shell
cp docker-compose.yml.dist docker-compose.yml

cp .ebextensions/00storage-efs-createfilesystem.config.dist .ebextensions/00storage-efs-createfilesystem.config
cp .ebextensions/01storage-efs-mountfilesystem.config.dist .ebextensions/01storage-efs-mountfilesystem.config
cp .ebextensions/02storage-docker-createvolumes.config.dist .ebextensions/02storage-docker-createvolumes.config
cp .ebextensions/environment.config.dist .ebextensions/environment.config
cp .ebextensions/instances.config.dist .ebextensions/instances.config
```

You can customize the EC2 instance type by updating `instances.config`

Copy the gateway configuration from the repository root 
```shell
cp -R ../../../../configs/gateway .
```

### 1. Configuration

* Open your AWS account, [VPC settings](https://console.aws.amazon.com/vpc/home#subnets), make sure that you've 
  selected the proper region based on your preference. On that webview, locate the first three subnets in the
  `Subnet Id` column and replace their values in `00storage-efs-createfilesystem.config` accordingly.

```shell
option_settings:
  aws:ec2:vpc:
     Subnets: subnet-XXXXXXXX, subnet-YYYYYYYY, subnet-ZZZZZZZZ
  aws:elasticbeanstalk:customoption:
    VPCId: "vpc-XXXXXXXX"
    ## Subnet Options
    SubnetA: "subnet-XXXXXXXX"
    SubnetB: "subnet-YYYYYYYY"
    SubnetC: "subnet-ZZZZZZZZ"
```

* Inside your `options.config`, update the `HOST` environment variable.
```yaml
option_settings:
    aws:elasticbeanstalk:application:environment:
        HOST: example.com
```  

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
(default is "Preview"): Helpdesk
```

Select option 3 as your application platform:
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

Select option 1 as platform branch:
```shell
Select a platform branch.
1) Docker running on 64bit Amazon Linux 2
2) Multi-container Docker running on 64bit Amazon Linux
3) Docker running on 64bit Amazon Linux
(default is 1):  1
```

Setting up SSH is optional.

### 3. Environment Creation

Create your compute resources and database by running the following command, then choose your secure username and password.
```shell
eb create preview --single --database

Enter an RDS DB username (default is "ebroot"):
Enter an RDS DB master password: 
Retype password to confirm:
```

The process might take about 10 minutes. After you see successfully deployed, you can locate your database host by navigating to your [EBS Environment](https://console.aws.amazon.com/elasticbeanstalk/home#/environments), then select configuration.

### 4. Enabling HTTPS

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

### 5. Helpdesk setup

To set up your helpdesk, you can either SSH to your environment, or choose to set up the helpdesk using the graphical interface.

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

----

# Configuring PHP

The default PHP config can be customised by copying configuration files into
the containers.

1. Create a `php/custom.ini` file within this directory
2. Add your PHP configuration to the file
3. Update the `volumes` definition for the `supportpal` and `supportpal_cron`
   containers in `docker-compose.yml`:
   ```
   - ./php/custom.ini:/usr/local/etc/php/conf.d/9999-custom-config.ini
   ```
   You can change the `9999` in the filename to control the priority of the configuration.
   `9999` means it is loaded last.
4. Redeploy the application
   ```bash
   eb deploy production
   ```

----

## Customize SupportPal

To [customize](https://docs.supportpal.com/current/Customisation) SupportPal:
1. Place your customizations in the relevant `customizations` directory.

   For example, `customizations/languages/de` would be used for German translation files.
3. Redeploy the application
```bash
eb deploy preview
```

----

## Upgrade SupportPal

Before upgrading, we recommend that you take a full backup of all your files and configurations.

* Make sure that you backup your EFS filesystem on AWS (all files and directories in your `/supportpal` directory)
* Make sure that you have a recent backup of your RDS database

To upgrade to a new SupportPal version:
1. Open `.ebextensions/environment.config`
2. Change the application version
```
APP_VERSION: 3.3.1
```
3. Redeploy the application
```bash
eb deploy preview
```

----

## Debugging

If you have any problems, run `eb logs preview` to read the log files.
