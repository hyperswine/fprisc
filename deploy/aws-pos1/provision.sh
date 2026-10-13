#!/bin/sh
# One-time AWS resources for POS v1 (new AWS experience: everything in the
# project's Region).  Idempotent: re-running finds what exists.  State goes to
# ./state.env (instance id, Elastic IP, hostname) for deploy.sh.
#
#   AWS_PROFILE=fprisc ./provision.sh
set -eu
here=$(cd "$(dirname "$0")" && pwd)
: "${AWS_PROFILE:=fprisc}"; export AWS_PROFILE
REGION=${REGION:-ap-southeast-2}; export AWS_DEFAULT_REGION=$REGION
NAME=${NAME:-pos1}
TYPE=${TYPE:-t4g.small}
KEY=${KEY:-pos1-key}
KEYFILE=${KEYFILE:-$HOME/.ssh/$KEY.pem}
SSH_CIDR=${SSH_CIDR:-$(curl -fsS https://checkip.amazonaws.com | tr -d '\n')/32}
tag="ResourceType=%s,Tags=[{Key=Name,Value=$NAME},{Key=app,Value=pos1}]"

# key pair: the private half only ever lives in ~/.ssh
if ! aws ec2 describe-key-pairs --key-names "$KEY" >/dev/null 2>&1; then
  umask 077
  aws ec2 create-key-pair --key-name "$KEY" --key-type ed25519 \
    --tag-specifications "$(printf "$tag" key-pair)" --query KeyMaterial --output text > "$KEYFILE"
  chmod 600 "$KEYFILE"; echo "key pair $KEY -> $KEYFILE"
fi

vpc=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
sg=$(aws ec2 describe-security-groups --filters Name=group-name,Values="$NAME-web" Name=vpc-id,Values="$vpc" --query 'SecurityGroups[0].GroupId' --output text)
if [ "$sg" = None ]; then
  sg=$(aws ec2 create-security-group --group-name "$NAME-web" --vpc-id "$vpc" \
    --description "POS v1: HTTP/HTTPS from anywhere, SSH from the operator" \
    --tag-specifications "$(printf "$tag" security-group)" --query GroupId --output text)
  aws ec2 authorize-security-group-ingress --group-id "$sg" --ip-permissions \
    "IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0,Description=http-acme}]" \
    "IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=0.0.0.0/0,Description=https}]" \
    "IpProtocol=udp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=0.0.0.0/0,Description=http3}]" \
    "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=$SSH_CIDR,Description=operator-ssh}]" >/dev/null
  echo "security group $sg (ssh from $SSH_CIDR)"
fi

iid=$(aws ec2 describe-instances --filters Name=tag:Name,Values="$NAME" \
  Name=instance-state-name,Values=pending,running,stopping,stopped \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
if [ "$iid" = None ]; then
  ami=$(aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64 --query Parameter.Value --output text)
  iid=$(aws ec2 run-instances --image-id "$ami" --instance-type "$TYPE" --key-name "$KEY" \
    --security-group-ids "$sg" \
    --credit-specification CpuCredits=standard \
    --metadata-options HttpTokens=required,HttpEndpoint=enabled,HttpPutResponseHopLimit=1 \
    --block-device-mappings 'DeviceName=/dev/xvda,Ebs={VolumeSize=20,VolumeType=gp3,Encrypted=true,DeleteOnTermination=true}' \
    --tag-specifications "$(printf "$tag" instance)" "$(printf "$tag" volume)" \
    --query 'Instances[0].InstanceId' --output text)
  echo "instance $iid ($TYPE, $ami)"
fi
aws ec2 wait instance-running --instance-ids "$iid"

eip=$(aws ec2 describe-addresses --filters Name=tag:Name,Values="$NAME" --query 'Addresses[0].AllocationId' --output text)
if [ "$eip" = None ]; then
  eip=$(aws ec2 allocate-address --domain vpc --tag-specifications "$(printf "$tag" elastic-ip)" --query AllocationId --output text)
fi
aws ec2 associate-address --instance-id "$iid" --allocation-id "$eip" --allow-reassociation >/dev/null
ip=$(aws ec2 describe-addresses --allocation-ids "$eip" --query 'Addresses[0].PublicIp' --output text)

cat > "$here/state.env" <<STATE
INSTANCE_ID=$iid
SECURITY_GROUP=$sg
EIP_ALLOC=$eip
PUBLIC_IP=$ip
SSH_KEY=$KEYFILE
POS1_HOSTS=$(echo "$ip" | tr . -).sslip.io
STATE
cat "$here/state.env"
