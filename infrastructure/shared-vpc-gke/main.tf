# Copyright 2019 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

###############################################################################
#                          Host and service projects                          #
###############################################################################

# the container.hostServiceAgentUser role is needed for GKE on shared VPC
# see: https://cloud.google.com/kubernetes-engine/docs/how-to/cluster-shared-vpc#grant_host_service_agent_role

module "project-host" {
  source          = "../../modules/project"
  parent          = var.root_node
  billing_account = var.billing_account_id
  prefix          = var.prefix
  name            = "net"
  services        = concat(var.project_services, ["dns.googleapis.com"])
  iam_roles = [
    "roles/container.hostServiceAgentUser", "roles/owner"
  ]
  iam_members = {
    "roles/container.hostServiceAgentUser" = [
      "serviceAccount:${module.project-svc-gke.gke_service_account}"
    ]
    "roles/owner" = var.owners_host
  }
}

module "project-svc-gce" {
  source          = "../../modules/project"
  parent          = var.root_node
  billing_account = var.billing_account_id
  prefix          = var.prefix
  name            = "gce"
  services        = var.project_services
  oslogin         = true
  oslogin_admins  = var.owners_gce
  iam_roles = [
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/owner"
  ]
  iam_members = {
    "roles/logging.logWriter"       = [module.vm-bastion.service_account_iam_email],
    "roles/monitoring.metricWriter" = [module.vm-bastion.service_account_iam_email],
    "roles/owner"                   = var.owners_gce,
  }
}

# the container.developer role assigned to the bastion instance service account
# allows to fetch GKE credentials from bastion for clusters in this project

module "project-svc-gke" {
  source          = "../../modules/project"
  parent          = var.root_node
  billing_account = var.billing_account_id
  prefix          = var.prefix
  name            = "gke"
  services        = var.project_services
  iam_roles = [
    "roles/container.developer",
    "roles/owner",
  ]
  iam_members = {
    "roles/owner"               = var.owners_gke
    "roles/container.developer" = [module.vm-bastion.service_account_iam_email]
  }
}

################################################################################
#                                  Networking                                  #
################################################################################

# subnet IAM bindings control which identities can use the individual subnets

module "vpc-shared" {
  source          = "../../modules/net-vpc"
  project_id      = module.project-host.project_id
  name            = "shared-vpc"
  shared_vpc_host = true
  shared_vpc_service_projects = [
    module.project-svc-gce.project_id,
    module.project-svc-gke.project_id
  ]
  subnets = [
    {
      ip_cidr_range      = var.ip_ranges.gce
      name               = "gce"
      region             = var.region
      secondary_ip_range = {}
    },
    {
      ip_cidr_range = var.ip_ranges.gke
      name          = "gke"
      region        = var.region
      secondary_ip_range = {
        pods     = var.ip_secondary_ranges.gke-pods
        services = var.ip_secondary_ranges.gke-services
      }
    }
  ]
  iam_roles = {
    "${var.region}/gke" = ["roles/compute.networkUser", "roles/compute.securityAdmin"]
    "${var.region}/gce" = ["roles/compute.networkUser"]
  }
  iam_members = {
    "${var.region}/gce" = {
      "roles/compute.networkUser" = concat(var.owners_gce, [
        "serviceAccount:${module.project-svc-gce.cloudsvc_service_account}",
      ])
    }
    "${var.region}/gke" = {
      "roles/compute.networkUser" = concat(var.owners_gke, [
        "serviceAccount:${module.project-svc-gke.cloudsvc_service_account}",
        "serviceAccount:${module.project-svc-gke.gke_service_account}",
      ])
      "roles/compute.securityAdmin" = [
        "serviceAccount:${module.project-svc-gke.gke_service_account}",
      ]
    }
  }
}

module "vpc-shared-firewall" {
  source               = "../../modules/net-vpc-firewall"
  project_id           = module.project-host.project_id
  network              = module.vpc-shared.name
  admin_ranges_enabled = true
  admin_ranges         = values(var.ip_ranges)
}

module "nat" {
  source         = "../../modules/net-cloudnat"
  project_id     = module.project-host.project_id
  region         = var.region
  name           = "vpc-shared"
  router_create  = true
  router_network = module.vpc-shared.name
}

################################################################################
#                                     DNS                                      #
################################################################################

module "host-dns" {
  source          = "../../modules/dns"
  project_id      = module.project-host.project_id
  type            = "private"
  name            = "example"
  domain          = "example.com."
  client_networks = [module.vpc-shared.self_link]
  recordsets = [
    { name = "localhost", type = "A", ttl = 300, records = ["127.0.0.1"] },
    { name = "bastion", type = "A", ttl = 300, records = module.vm-bastion.internal_ips },
  ]
}

################################################################################
#                                     VM                                      #
################################################################################

module "vm-bastion" {
  source     = "../../modules/compute-vm"
  project_id = module.project-svc-gce.project_id
  region     = var.region
  zone       = "${var.region}-b"
  name       = "bastion"
  network_interfaces = [{
    network    = module.vpc-shared.self_link,
    subnetwork = lookup(module.vpc-shared.subnet_self_links, "${var.region}/gce", null),
    nat        = false,
    addresses  = null
  }]
  instance_count = 1
  tags           = ["ssh"]
  metadata = {
    startup-script = join("\n", [
      "#! /bin/bash",
      "apt-get update",
      "apt-get install -y bash-completion kubectl dnsutils"
    ])
  }
  service_account_create = true
}

################################################################################
#                                     GKE                                      #
################################################################################

module "cluster-1" {
  source                    = "../../modules/gke-cluster"
  name                      = "cluster-1"
  project_id                = module.project-svc-gke.project_id
  location                  = "${var.region}-b"
  network                   = module.vpc-shared.self_link
  subnetwork                = module.vpc-shared.subnet_self_links["${var.region}/gke"]
  secondary_range_pods      = "pods"
  secondary_range_services  = "services"
  default_max_pods_per_node = 32
  labels = {
    environment = "test"
  }
  master_authorized_ranges = {
    internal-vms = var.ip_ranges.gce
  }
  private_cluster_config = {
    enable_private_nodes    = true
    enable_private_endpoint = true
    master_ipv4_cidr_block  = var.private_service_ranges.cluster-1
  }
}

module "cluster-1-nodepool-1" {
  source                      = "../../modules/gke-nodepool"
  name                        = "nodepool-1"
  project_id                  = module.project-svc-gke.project_id
  location                    = module.cluster-1.location
  cluster_name                = module.cluster-1.name
  node_config_service_account = module.service-account-gke-node.email
}

# roles assigned via this module use non-authoritative IAM bindings at the
# project level, with no risk of conflicts with pre-existing roles

module "service-account-gke-node" {
  source     = "../../modules/iam-service-accounts"
  project_id = module.project-svc-gke.project_id
  names      = ["gke-node"]
  iam_project_roles = {
    (module.project-svc-gke.project_id) = [
      "roles/logging.logWriter",
      "roles/monitoring.metricWriter",
    ]
  }
}
