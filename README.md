# Azure Quota Analysis

### App Service Quota

We first need to login to our Azure Subscription 

```bash

az login

```

Then we specify our target subscription id, if we have more than one subscription we can pick from

```bash

# List all the subscriptions available to you
az account list

# Set the subscription id you wish to use
az account set -s "{YOUR_SUBSCRIPTION_ID}"

# Display the details for your currently specified tenant and account if necessary
az account show


```

### Check App Service Availability


```bash

cd app-service-analysis

appservice_quota_by_region.sh --sku {TARGET_SKU}

./appservice_quota_by_region.sh --sku B1

```