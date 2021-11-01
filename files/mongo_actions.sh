#!/bin/bash
set -e
set -o pipefail

unset SERVICE_NAME
unset ACTION_TYPE
unset WORKSPACE
unset ENV_TYPE
unset AWS_PROFILE
unset DBHOST
unset DBNAME
unset INIT_DB_ENVIRONMENT

usage() {
  cat <<EOM
    Usage:
    mongo_actions.sh -s|--service_name <SERVICE_NAME> -a|--action <mongo_backup/mongo_restore> -w|--workspace <Terraform workspace> -e|--env_type <prod/non-prod> -p|--profile <AWS_PROFILE> -dbh|--dbhost <Mongo DB URI> -dbs|--source_db <source workspace to copy DB from on restore(optional)>
    I.E. for backup 
    mongo_actions.sh --service_name myService --action mongo_backup --workspace my-data --env_type non-prod --profile my-aws-profile --dbhost mongodb+srv://my-mongodb-connection-string
    I.E. for restore
    mongo_actions.sh --service_name myService --action mongo_restore --workspace my-data --env_type non-prod --profile my-aws-profile --dbhost mongodb+srv://my-mongodb-connection-string --source_db test-data
    I.E. for clone
    mongo_actions.sh --service_name myService --action mongo_restore --workspace my-data --env_type non-prod --profile my-aws-profile --dbhost mongodb+srv://my-mongodb-connection-string --source_db test-data
EOM
    exit 1
}

while [[ $# -gt 0 ]]; do
  key="$1"
  case $key in
    -s|--service_name)
      SERVICE_NAME="$2"
      shift # past argument
      shift # past value
      ;;
    -a|--action)
      ACTION_TYPE="$2"
      shift # past argument
      shift # past value
      ;;
    -w|--workspace)
      WORKSPACE="$2"
      shift # past argument
      shift # past value
      ;;
    -e|--env_type)
      ENV_TYPE="$2"
      shift # past argument
      shift # past value
      ;;
    -p|--profile)
      AWS_PROFILE="$2"
      if [[ -f "~/.aws/credentilas" ]] || [[ -f "~/.aws/config" ]];
      then
        AWS_PROFILE="$2"
      else 
        aws configure set region us-east-1
        unset AWS_PROFILE
      fi
      shift # past argument
      shift # past value
      ;;
    -dbh|--dbhost)
      DBHOST="$2"
      shift # past argument
      shift # past value
      ;;
    -sdb|--source_db)
        if [[ "$2" == "NULL" ]];
        then 
            unset INIT_DB_ENVIRONMENT
        else 
            INIT_DB_ENVIRONMENT="$2"
        fi
        shift # past argument
        shift # past value
      ;;
    -h|--help)
        usage
        shift # past argument
        shift # past value
      ;;
    *)    # unknown option
      echo "Error in command line parsing: unknown parameter ${*}" >&2
      exit 1
  esac
done

: ${SERVICE_NAME:?Missing -s|--service_name type -h for help}
: ${ACTION_TYPE:?Missing -a|--action type -h for help}
: ${WORKSPACE:?Missing -w|--workspace type -h for help}
: ${ENV_TYPE:?Missing -e|--env_type type -h for help}
: ${DBHOST:?Missing -dbh|--dbhost type -h for help}

### SET DEFAULT PROFILE ####

### VALIDATE MONGODB URI FORMAT ###
if [[ "$DBHOST" =~ ^mongodb\+srv\:\/\/.*$ ]]; then
    echo "Validating mongoDB uri"
else
    echo "Please use a valid mongoDB uri mongodb+srv://myMongo-server"
    exit 1
fi

### GET TARGET DB CONNECTION DETAILS FROM SSM ###
if [[ -z "${AWS_PROFILE}" ]]; then
DBNAME=$(aws ssm get-parameter --name "/infra/$WORKSPACE/db-name" --query 'Parameter.Value' --output text)
DBUSER=$(aws ssm get-parameter --name "/infra/$WORKSPACE/db-username" --with-decryption --query 'Parameter.Value' --output text)
DBPASSWORD=$(aws ssm get-parameter --name "/infra/$WORKSPACE/db-password" --with-decryption --query 'Parameter.Value' --output text)
else
DBNAME=$(aws ssm get-parameter --name "/infra/$WORKSPACE/db-name" --query 'Parameter.Value' --profile $AWS_PROFILE --output text)
DBUSER=$(aws ssm get-parameter --name "/infra/$WORKSPACE/db-username" --with-decryption --query 'Parameter.Value' --profile $AWS_PROFILE --output text)
DBPASSWORD=$(aws ssm get-parameter --name "/infra/$WORKSPACE/db-password" --with-decryption --query 'Parameter.Value' --profile $AWS_PROFILE --output text)
fi
if [[ -z "$DBNAME"  ]] || [[ -z "$DBUSER" ]] || [[ -z "$DBPASSWORD" ]]; then
        echo "Could not retrieve one or more parameters from SSM!!!"
        exit 1
fi

### VALIDATE DUMP EXISTS FOR RESTORE ###
if [[ "${ACTION_TYPE}" == "mongo_restore" ]]; then
  if [[ -z "${AWS_PROFILE}" ]]; then
    aws s3api head-object --bucket "${SERVICE_NAME}-${ENV_TYPE}-mongodb-dumps" --key $WORKSPACE/$DBNAME.tar --no-cli-pager || object_not_exist=true 
  else
    aws s3api head-object --bucket "${SERVICE_NAME}-${ENV_TYPE}-mongodb-dumps" --key $WORKSPACE/$DBNAME.tar --profile $AWS_PROFILE --no-cli-pager || object_not_exist=true 
  fi
  if [[ $object_not_exist && -z "${INIT_DB_ENVIRONMENT}" ]]; then
      echo "Dump file not found not performing restore"
      exit 0
  elif [[ $object_not_exist && -n "${INIT_DB_ENVIRONMENT}" ]]
  then
      ACTION_TYPE="mongo_clone"
  else
      echo "Starting Restore..." 
  fi
fi

### VALIDATE DOCKER IS INTALLED AND RUNNING ###
if [[ `docker ps` ]]; then
  echo "Preparing to ${ACTION_TYPE}..."
  echo "pulling mongo docker image..."
  docker pull mongo
else
  echo "docker is missing or docker daemon is not running !!!"
  exit 127
  fi
fi

### MONGO DB BACKUP ###
mongo_backup() {
  if [[ -z "${AWS_PROFILE}" ]]; then
    aws s3api head-bucket --bucket ${SERVICE_NAME}-${ENV_TYPE}-mongodb-dumps || bucket_not_exist=true
  else
    aws s3api head-bucket --bucket ${SERVICE_NAME}-${ENV_TYPE}-mongodb-dumps --profile $AWS_PROFILE || bucket_not_exist=true
  fi
  if [ $bucket_not_exist ]; then
    echo "Bucket not found, Creating new bucket ${SERVICE_NAME}-${ENV_TYPE}-mongodb-dumps..."
    if [[ -z "${AWS_PROFILE}" ]]; then
      aws s3api create-bucket --bucket ${SERVICE_NAME}-${ENV_TYPE}-mongodb-dumps --no-cli-pager
      aws s3api put-bucket-versioning --bucket ${SERVICE_NAME}-${ENV_TYPE}-mongodb-dumps --versioning-configuration Status=Enabled
      aws s3api put-public-access-block --bucket ${SERVICE_NAME}-${ENV_TYPE}-mongodb-dumps --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
    else
        aws s3api create-bucket --bucket ${SERVICE_NAME}-${ENV_TYPE}-mongodb-dumps --profile $AWS_PROFILE --no-cli-pager
      aws s3api put-bucket-versioning --bucket ${SERVICE_NAME}-${ENV_TYPE}-mongodb-dumps --versioning-configuration Status=Enabled
      aws s3api put-public-access-block --bucket ${SERVICE_NAME}-${ENV_TYPE}-mongodb-dumps --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" --profile $AWS_PROFILE
    fi
  fi
  [ ! "$(docker ps | grep mongodocker)" ] && docker run --name mongodocker -i -d mongo bash
  docker exec -i mongodocker /usr/bin/mongodump --uri "$DBHOST/$DBNAME" -u$DBUSER -p$DBPASSWORD --gzip -o /tmp/$DBNAME
  docker cp mongodocker:/tmp/$DBNAME /tmp/$DBNAME
  tar cvf /tmp/$DBNAME.tar -C /tmp/$DBNAME/ .
  if [[ -z "${AWS_PROFILE}" ]]; then
    aws s3 cp /tmp/$DBNAME.tar s3://${SERVICE_NAME}-${ENV_TYPE}-mongodb-dumps/$WORKSPACE/
  else
    aws s3 cp /tmp/$DBNAME.tar s3://${SERVICE_NAME}-${ENV_TYPE}-mongodb-dumps/$WORKSPACE/ --profile $AWS_PROFILE
  rm -rf /tmp/$DBNAME.tar /tmp/$DBNAME
  docker rm -f mongodocker
}

mongo_clone() {
  echo "Copying init db..."
  ### GET SSM PARAMS OF SOURCE DB ###
  if [[ -z "${AWS_PROFILE}" ]]; then
    SDBNAME=$(aws ssm get-parameter --name "/infra/$INIT_DB_ENVIRONMENT/db-name" --query 'Parameter.Value' --output text)
    SDBHOST=$(aws ssm get-parameter --name "/infra/$INIT_DB_ENVIRONMENT/db-host" --with-decryption --query 'Parameter.Value' --output text)
    SDBUSER=$(aws ssm get-parameter --name "/infra/$INIT_DB_ENVIRONMENT/db-username" --with-decryption --query 'Parameter.Value' --output text)
    SDBPASSWORD=$(aws ssm get-parameter --name "/infra/$INIT_DB_ENVIRONMENT/db-password" --with-decryption --query 'Parameter.Value' --output text)
  else
    SDBNAME=$(aws ssm get-parameter --name "/infra/$INIT_DB_ENVIRONMENT/db-name" --query 'Parameter.Value' --profile $AWS_PROFILE  --output text)
    SDBHOST=$(aws ssm get-parameter --name "/infra/$INIT_DB_ENVIRONMENT/db-host" --with-decryption --query 'Parameter.Value' --profile $AWS_PROFILE  --output text)
    SDBUSER=$(aws ssm get-parameter --name "/infra/$INIT_DB_ENVIRONMENT/db-username" --with-decryption --query 'Parameter.Value' --profile $AWS_PROFILE  --output text)
    SDBPASSWORD=$(aws ssm get-parameter --name "/infra/$INIT_DB_ENVIRONMENT/db-password" --with-decryption --query 'Parameter.Value' --profile $AWS_PROFILE  --output text)
  fi
  if [[ -z "$SDBUSER" ]] || [[ -z "$SDBPASSWORD" ]] || [[ -z "$SDBHOST" ]]; then
      echo "Could not retrieve one or more parameters from SSM!!!"
      exit 1
  fi
  SDBHOST="mongodb+srv://+$SDBHOST"
  [ ! "$(docker ps | grep mongodocker)" ] && docker run --name mongodocker -i -d mongo bash
  docker exec -i mongodocker /bin/bash <<EOF 
  mongodump --uri "$SDBHOST/$SDBNAME" -u$SDBUSER -p$SDBPASSWORD --gzip --archive | mongorestore --uri "$DBHOST" -u$DBUSER -p$DBPASSWORD --nsFrom="$SDBNAME.*" --nsTo="$DBNAME.*" --gzip --archive
EOF
  docker rm -f mongodocker
}

### MONGO DB RESTORE
mongo_restore() {
  if [[ -z "${AWS_PROFILE}" ]]; then
    aws s3 cp s3://${SERVICE_NAME}-${ENV_TYPE}-mongodb-dumps/$WORKSPACE/$DBNAME.tar /tmp/ --profile $AWS_PROFILE
  else
    aws s3 cp s3://${SERVICE_NAME}-${ENV_TYPE}-mongodb-dumps/$WORKSPACE/$DBNAME.tar /tmp/ --profile $AWS_PROFILE
  fi
  mkdir -p /tmp/dump
  tar xvf /tmp/$DBNAME.tar -C /tmp/dump
  [ ! "$(docker ps | grep mongodocker)" ] && docker run --name mongodocker -i -d mongo bash
  docker cp /tmp/dump mongodocker:/tmp/dump
  docker exec -i mongodocker /usr/bin/mongorestore --uri "$DBHOST" -u$DBUSER -p$DBPASSWORD --gzip /tmp/dump
  rm -rf /tmp/$DBNAME.tar /tmp/dump
  docker rm -f mongodocker
}

$ACTION_TYPE
