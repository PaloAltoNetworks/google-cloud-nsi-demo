# -------------------------------------------------------------------------------------
# Provider configuration
# -------------------------------------------------------------------------------------

terraform {
  required_version = "> 1.5, < 2.0"

  required_providers {
    google = {
      source = "hashicorp/google"
    }
    google-beta = {
      source = "hashicorp/google-beta"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region

  default_labels = {
    panw = "true"
  }
}

provider "google-beta" {
  project = var.project_id
  region  = var.region

  default_labels = {
    panw = "true"
  }
}

data "google_project" "current" {
  project_id = var.project_id
}
# -------------------------------------------------------------------------------------
# Localized variables
# -------------------------------------------------------------------------------------

locals {
  prefix                   = var.prefix != null && var.prefix != "" ? "${var.prefix}-" : ""
  gke_subnet_cidr_cluster  = "10.20.0.0/16"
  gke_subnet_cidr_services = "10.30.0.0/16"
  gke_version              = "1.28"
}


# -------------------------------------------------------------------------------------
# Create VPC network and Cloud NAT.
# -------------------------------------------------------------------------------------

// Create consumer VPC
resource "google_compute_network" "main" {
  name                    = "${local.prefix}consumer-vpc"
  auto_create_subnetworks = false
}

// Create consumer subnetwork
resource "google_compute_subnetwork" "main" {
  name          = "${local.prefix}${var.region}-consumer"
  ip_cidr_range = var.subnet_cidr
  region        = var.region
  network       = google_compute_network.main.id

  secondary_ip_range {
    range_name    = "${local.prefix}${var.region}-cluster"
    ip_cidr_range = local.gke_subnet_cidr_cluster
  }

  secondary_ip_range {
    range_name    = "${local.prefix}${var.region}-services"
    ip_cidr_range = local.gke_subnet_cidr_services
  }
}

// Allow external access from var.mgmt_allow_ips
resource "google_compute_firewall" "external" {
  name          = "${local.prefix}consumer-allow-external"
  network       = google_compute_network.main.name
  source_ranges = var.mgmt_allow_ips

  allow {
    protocol = "tcp"
    ports    = ["80", "22"]
  }
}

// Allow all intra-VPC traffic within the consumer VPC
resource "google_compute_firewall" "local" {
  name          = "${local.prefix}consumer-allow-local"
  network       = google_compute_network.main.name
  source_ranges = [var.subnet_cidr]

  allow {
    protocol = "all"
    ports    = []
  }
}

// Create cloud router for cloud NAT.
resource "google_compute_router" "main" {
  name    = "${local.prefix}${var.region}-consumer-router"
  region  = var.region
  network = google_compute_network.main.id
}

// Create cloud NAT for outbound internet access.
resource "google_compute_router_nat" "main" {
  name                               = "${local.prefix}${var.region}-consumer-nat"
  router                             = google_compute_router.main.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}



# -------------------------------------------------------------------------------------
# Create web & client VMs
# -------------------------------------------------------------------------------------

data "google_compute_zones" "available" {
  region = var.region
}


resource "google_compute_instance" "web" {
  name                      = "${local.prefix}web-vm"
  machine_type              = "f1-micro"
  zone                      = data.google_compute_zones.available.names[0]
  can_ip_forward            = false
  allow_stopping_for_update = true

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2204-lts"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.main.id
    network_ip = cidrhost(var.subnet_cidr, 20)
  }

  metadata = {
    serial-port-enable = true
  }

  metadata_startup_script = file("./yaml/startup-script-server.sh")

  service_account {
    scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
  }

  depends_on = [
    google_compute_router_nat.main
  ]
}

resource "google_compute_instance" "client" {
  name                      = "${local.prefix}client-vm"
  machine_type              = "f1-micro"
  zone                      = data.google_compute_zones.available.names[0]
  can_ip_forward            = false
  allow_stopping_for_update = true
  tags             = ["client-vm"]
  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2204-lts"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.main.id
    network_ip = cidrhost(var.subnet_cidr, 10)
  }

  metadata = {
    serial-port-enable = true
  }

  metadata_startup_script = file("./yaml/startup-script-client.sh")

  service_account {
    scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
  }

  depends_on = [
    google_compute_router_nat.main,
    google_secret_manager_secret_version.ngfw_ca_version,
    google_secret_manager_secret_iam_member.default_gce_access
  ]
}

# -------------------------------------------------------------------------------------
# Create GKE cluster
# -------------------------------------------------------------------------------------

module "gke" {
  source = "terraform-google-modules/kubernetes-engine/google"
  version                    = "36.1.0"
  project_id                  = var.project_id
  name                        = "${local.prefix}cluster1"
  regional                    = false
  region                      = var.region
  zones                       = ["${data.google_compute_zones.available.names[0]}"]
  network                     = google_compute_network.main.name
  subnetwork                  = google_compute_subnetwork.main.name
  ip_range_pods               = google_compute_subnetwork.main.secondary_ip_range[0].range_name
  ip_range_services           = google_compute_subnetwork.main.secondary_ip_range[1].range_name
  release_channel             = "UNSPECIFIED"
  create_service_account      = true
  http_load_balancing         = true
  network_policy              = false
  horizontal_pod_autoscaling  = false
  deletion_protection         = false
  enable_intranode_visibility = true # Must be enabled for pod-to-pod traffic mirroring to SW-NGFW.
  # kubernetes_version          = "1.33.4-gke.1350000"
  node_pools = [
    {
      name               = "default-node-pool"
      machine_type       = "e2-standard-2"
      initial_node_count = 1
      auto_upgrade       = true
    }
  ]

  node_pools_oauth_scopes = {
    all = []
    default-node-pool = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
  }
}

data "google_container_cluster" "main" {
  name     = module.gke.name
  location = data.google_compute_zones.available.names[1]
}


# Create the Secret Manager secret container
resource "google_secret_manager_secret" "ngfw_ca" {
  secret_id = "ngfw-ca"

  replication {
    auto {}
  }

  labels = {
    purpose = "ngfw-root-ca"
    managed_by = "terraform"
  }
}

# Upload the CA certificate from your bootstrap folder
resource "google_secret_manager_secret_version" "ngfw_ca_version" {
  secret      = google_secret_manager_secret.ngfw_ca.id
  secret_data = file("${path.module}/yaml/decryption.crt")
}

# Grant default GCE service account read access
resource "google_secret_manager_secret_iam_member" "default_gce_access" {
  secret_id = google_secret_manager_secret.ngfw_ca.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${data.google_project.current.number}-compute@developer.gserviceaccount.com"
}
