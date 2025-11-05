output "ENVIRONMENT_VARIABLES" {
  value = <<EOT

export PRODUCER_PROJECT=${var.project_id}
export DATA_VPC=${google_compute_network.data.name}
export DATA_SUBNET=${google_compute_subnetwork.data.name}
export REGION=${var.region}
export ZONE=${data.google_compute_zones.available.names[0]}
export BACKEND_SERVICE=${google_compute_region_backend_service.main.self_link}
EOT

}