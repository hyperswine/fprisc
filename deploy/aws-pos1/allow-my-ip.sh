#!/bin/sh
# SSH is allowed from one address.  When yours changes (ssh times out),
# replace the rule with your current public IP:
#   ./allow-my-ip.sh
set -eu
here=$(cd "$(dirname "$0")" && pwd)
. "$here/state.env"
: "${AWS_PROFILE:=fprisc}"; export AWS_PROFILE AWS_DEFAULT_REGION=${REGION:-ap-southeast-2}
me=$(curl -fsS https://checkip.amazonaws.com | tr -d '\n')/32
old=$(aws ec2 describe-security-group-rules --filters Name=group-id,Values="$SECURITY_GROUP" \
  --query 'SecurityGroupRules[?!IsEgress && FromPort==`22`].SecurityGroupRuleId' --output text)
[ -z "$old" ] || aws ec2 revoke-security-group-ingress --group-id "$SECURITY_GROUP" --security-group-rule-ids $old >/dev/null
aws ec2 authorize-security-group-ingress --group-id "$SECURITY_GROUP" --ip-permissions \
  "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=$me,Description=operator-ssh}]" >/dev/null
echo "ssh now allowed from $me"
