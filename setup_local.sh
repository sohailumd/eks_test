#!/usr/bin/env bash

set -exu

export AWS_DEFAULT_REGION="us-west-2"

if [ "${env}" = "dev" ]; then
    export dev_bucket=terraform-cdk-aws-athenaplatform-dev
    export dev_dynamotable=terraform-cdk-aws-athenaplatform-dev
    export bucket="${dev_bucket}"
    export dynamotable="${dev_dynamotable}"

  elif [ "${env}" = "nonprod" ]; then 
    export nonprod_bucket=eks-7210-s3-bucket-nonprod
    export nonprod_dynamotable=athena_rds-tf-state-lock
    export bucket="${nonprod_bucket}"
    export dynamotable="${nonprod_dynamotable}"
      
  else
   [ "${env}" = "prod" ];
    export prod_bucket=terraform-cdk-aws-athenaplatform-prod
    export prod_dynamotable=terraform-cdk-aws-athenaplatform-prod
    export bucket="${prod_bucket}"
    export dynamotable="${prod_dynamotable}"
fi

rm -rf .terraform

tf_init () {
      terraform init -backend-config="bucket=${bucket}" \
                -backend-config="dynamodb_table=${dynamotable}" \
                        -backend-config="key=athena/eks/eks_${prodid}_${env}/terraform.tfstate"\
                                -backend=true -force-copy -get=true -input=false -no-color
}

if [ "${COMMAND}" = "plan" ]; then
      tf_init
      terraform plan -var prodid=${prodid} -var env=${env}

  elif [ "${COMMAND}" = "apply" ]; then 
      tf_init
      terraform plan -var prodid=${prodid} -var env=${env} 
      terraform apply -auto-approve -var prodid=${prodid} -var env=${env} 
      
  else
   [ "${COMMAND}" = "destroy" ];
      tf_init
      terraform destroy -auto-approve -var prodid=${prodid} -var env=${env}
fi