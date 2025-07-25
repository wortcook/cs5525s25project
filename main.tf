#############################################
# Thomas Jones
# CS5525
#############################################
# Terraform configuration for Google Cloud 
# LLM Infrastructure. This configuration sets
# up the necessary resources for running a 
# large language model (LLM) infrastructure
# on Google Cloud Platform (GCP) using Terraform.
#############################################
provider "google" {
  project = var.project
  region  = var.region
  zone    = var.zone
}

data "google_project" "project" {
}

# APIs used for the project. The terraform script
# will ensure these APIs are enabled before creating resources.
# They are not disabled on destroy to prevent issues with other
# projects that might be running on the same GCP account.
resource "google_project_service" "project_apis" {
  project  = var.project
  for_each = toset([
    "cloudresourcemanager.googleapis.com",
    "iam.googleapis.com",
    "run.googleapis.com",
    "compute.googleapis.com",
    "storage.googleapis.com",
    "artifactregistry.googleapis.com",
    "vpcaccess.googleapis.com",
    "pubsub.googleapis.com",
    "monitoring.googleapis.com",
  ])
  service                    = each.key
  disable_on_destroy         = false
  disable_dependent_services = false
}

# This resource introduces a delay between the destruction of the Cloud Run
# service and the subnetwork it uses. This prevents a race condition where
# Terraform tries to delete the subnetwork while its IP is still reserved
# by the Serverless VPC Access connector.
resource "time_sleep" "wait_for_ip_release" {
  destroy_duration = "60s"
  depends_on = [google_compute_subnetwork.llm-vpc-filter-subnet]
}


###############################################
# NETWORKING
###############################################

# VPC network for the LLM infrastructure.
resource "google_compute_network" "llm-vpc" {
  name                    = "llm-vpc"
  auto_create_subnetworks = false
  mtu                     = 1460

  depends_on = [google_project_service.project_apis]
}

# Firewall rule to allow HTTP and HTTPS traffic to the VPC network.
resource "google_compute_firewall" "default" {
  name        = "allow-http-https-ingress"
  network     = google_compute_network.llm-vpc.name # Reference the custom VPC network
  priority    = 100 # Lower number means higher priority
  direction   = "INGRESS"
  source_ranges = ["0.0.0.0/0"] # Allow HTTP/HTTPS from any source
  allow {
    protocol = "tcp"
    ports    = ["80", "443"] # Allow HTTP and HTTPS
  }
}


# Subnetwork for the filter services, bfilter and sfilter.
resource "google_compute_subnetwork" "llm-vpc-filter-subnet" {
  name          = "llm-vpc-filter-subnet"
  ip_cidr_range = var.filter_subnet
  region        = var.region
  private_ip_google_access = true
  network       = google_compute_network.llm-vpc.id
}


# Subnetwork for the LLM stub service.
resource "google_compute_subnetwork" "llmstub-subnet" {
  name          = "llmstub-subnet"
  ip_cidr_range = var.llm_subnet
  region        = var.region # Match your project's region
  network       = google_compute_network.llm-vpc.id

  private_ip_google_access = true

  depends_on = [google_project_service.project_apis, time_sleep.wait_for_ip_release]
}

# Generate a random suffix for the VPC Access Connector names to ensure uniqueness.
resource "random_id" "connector_suffix" {
  byte_length = 4  # Generates 16 hex characters
}

# VPC Access Connector for the filter services (bfilter and sfilter).
# The random suffix ensures that multiple runs of the script do not
# conflict with each other. Destroying connectors can take time, so
# by making the names random, we avoid potential naming collisions
# when the script is run multiple times.
# This allows the Cloud Run services to access other Cloud Run services
# and other resources in the VPC network without needing to make them publicly accessible.
resource "google_vpc_access_connector" "bfilter-connector" {
  name          = "bfilter-${random_id.connector_suffix.dec}"
  region        = var.region
  min_instances = var.bfilter_min_instances
  max_instances = var.bfilter_max_instances
  subnet {
    name = google_compute_subnetwork.llm-vpc-filter-subnet.name
  }
  depends_on = [google_project_service.project_apis, time_sleep.wait_for_ip_release]
}

# VPC Access Connector for the LLM stub service.
# Allows the bfilter service to access the LLM stub service
# within the subset without making it publicly accessible.
resource "google_vpc_access_connector" "llm-stub-connector" {
  name          = "llm-stub-${random_id.connector_suffix.dec}"
  region        = var.region
  min_instances = 2
  max_instances = 8
  subnet {
    name = google_compute_subnetwork.llmstub-subnet.name
  }
}



###############################
# STORAGE
###############################

# Storage bucket for model storage so that the sfilter services 
# can access the model files.
resource "google_storage_bucket" "model-store" {
  name     = "model-store-${var.project}"
  location = var.region
  labels   = local.common_labels

  # When deleting the bucket, this will also delete all objects in it.
  force_destroy = true

  uniform_bucket_level_access = true


  lifecycle {
    prevent_destroy = false
  }

  # Ensure the Storage API is enabled before creating the bucket.
  depends_on = [google_project_service.project_apis]
}

# Secondary storage bucket for storing secondary filter events.
# Note, we are using a bucket for this project to simplify the
# architecture. In a production system, you might want to
# use a more structured storage solution like BigQuery or Firestore.
resource "google_storage_bucket" "secondary-spam" {
  name     = "secondary-spam-${var.project}"
  location = var.region
  labels   = local.common_labels

  # When deleting the bucket, this will also delete all objects in it.
  force_destroy = true

  uniform_bucket_level_access = true
  lifecycle {
    prevent_destroy = false
  }

  # Ensure the Storage API is enabled before creating the bucket.
  depends_on = [google_project_service.project_apis]
}


###############################
# MODEL DOWNLOAD JOB
###############################

# Model downloader job to fetch the secondary model from a Git repository
# The job files are located in the `model-downloader` module.


# Module containing container build logic for the model downloader job.
module "model-downloader-build" {
  source     = "./model-downloader"
  project_id = var.project

  # Ensure Artifact Registry API is enabled before building/pushing images.
  depends_on = [google_project_service.project_apis] # Ensure VPC Access API is also enabled
}

# This resource triggers the model downloader job to run.
resource "null_resource" "model-download" {
  triggers = {
    # Re-run the job if the job definition, model name, or container image changes.
    job_id     = google_cloud_run_v2_job.model_downloader_job.id
    model_git_url = var.model_git_url
    image_id   = module.model-downloader-build.image_id
  }

  provisioner "local-exec" {
    # This command executes the Cloud Run Job.
    command = "gcloud run jobs execute ${google_cloud_run_v2_job.model_downloader_job.name} --region ${google_cloud_run_v2_job.model_downloader_job.location} --wait --project ${var.project}"
  }

  depends_on = [google_cloud_run_v2_job.model_downloader_job]
}

# Model downloader job to fetch the secondary model from a Git repository
resource "google_cloud_run_v2_job" "model_downloader_job" {
  name     = "model-downloader-job"
  location = var.region
  project  = var.project
  deletion_protection = false

  template {
    template {
      service_account = google_service_account.model_downloader_sa.email
      containers {
        image = module.model-downloader-build.image_name
        env {
          name  = "MODEL_GIT_URL"
          value = var.model_git_url
        }
        env {
          name  = "GCS_BUCKET_NAME"
          value = google_storage_bucket.model-store.name
        }
        resources {
          limits = {
            memory = "4Gi"
            cpu    = "2"
          }
        }
      }
      timeout = "3600s" # 1 hour
      max_retries = 5
    }
  }
  depends_on = [module.model-downloader-build, google_storage_bucket_iam_member.model_downloader_gcs_writer]
}



###############################################
# SERVICE ACCOUNTS & PERMISSIONS
###############################################

# Service account for the model downloader job.
resource "google_service_account" "model_downloader_sa" {
  account_id   = "model-downloader-sa"
  display_name = "Model Downloader Service Account"
  project      = var.project

  # Ensure the IAM API is enabled before creating the service account.
  depends_on = [google_project_service.project_apis]
}


# Service account for the LLM stub service.
resource "google_service_account" "llm_stub_sa" {
  account_id   = "llm-stub-sa"
  display_name = "LLM Stub Service Account"
  project      = var.project
  depends_on   = [google_project_service.project_apis]
}

#Service account for the sfilter service.
resource "google_service_account" "sfilter_sa" {
  account_id   = "sfilter-sa"
  display_name = "SFilter Service Account"
  project      = var.project
  depends_on   = [google_project_service.project_apis]
}

#Service account for the bfilter service.
resource "google_service_account" "bfilter_sa" {
  account_id   = "bfilter-sa"
  display_name = "BFilter Service Account"
  project      = var.project
  depends_on   = [google_project_service.project_apis]
}

# Grant the model downloader service account  permission to write to the model storage bucket.
resource "google_storage_bucket_iam_member" "model_downloader_gcs_writer" {
  bucket = google_storage_bucket.model-store.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.model_downloader_sa.email}"
}


# Grant the sfilter service account read access to the model bucket.
# This ensures the process within the container (running as this SA)
# can read files from the GCS FUSE volume mount.
resource "google_storage_bucket_iam_member" "sfilter_gcs_reader" {
  bucket = google_storage_bucket.model-store.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.sfilter_sa.email}"
}

# Grant the Cloud Run Service Agent permission to mount GCS volumes for services.
# This is required for the GCS volume mount feature to work, as Cloud Run
# infrastructure accesses the bucket on the service's behalf.
resource "google_storage_bucket_iam_member" "run_service_agent_gcs_mount_access" {
  bucket = google_storage_bucket.model-store.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:service-${data.google_project.project.number}@serverless-robot-prod.iam.gserviceaccount.com"
  depends_on = [google_project_service.project_apis] # Ensures the Run API is enabled, which creates the service agent.
}


# Grant bfilter service account permission to invoke llm-stub service.
resource "google_cloud_run_v2_service_iam_member" "bfilter_invokes_llmstub" {
  project  = var.project
  location = var.region
  name     = google_cloud_run_v2_service.llm-stub-service.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.bfilter_sa.email}"
}

# Grant bfilter service account permission to invoke sfilter service.
resource "google_cloud_run_v2_service_iam_member" "bfilter_invokes_sfilter" {
  project  = var.project
  location = var.region
  name     = google_cloud_run_v2_service.sfilter-service.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.bfilter_sa.email}"
}

# Grant bfilter service account permission to publish to Pub/Sub for jailbreak logging
resource "google_project_iam_member" "bfilter_pubsub_publisher" {
  project = var.project
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${google_service_account.bfilter_sa.email}"
}

# Grant the bfilter service account permission to publish to the secondary filter topic.
resource "google_pubsub_topic_iam_member" "bfilter_publishes_to_secondary_filter" {
  project = var.project
  topic   = google_pubsub_topic.secondary_filter_topic.name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${google_service_account.bfilter_sa.email}"

  depends_on = [google_pubsub_topic.secondary_filter_topic, google_service_account.bfilter_sa]
}


# Build permission to allow system pubsub service account to read from the secondary spam bucket.
resource "google_storage_bucket_iam_member" "pubsub_to_bucket_reader" {
  bucket = google_storage_bucket.secondary-spam.name
  member = "serviceAccount:service-${data.google_project.project.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
  role   = "roles/storage.legacyBucketReader"

    depends_on = [
        google_storage_bucket.secondary-spam
    ]
}

# Write permission to allow system pubsub service account to write to the secondary spam bucket.
resource "google_storage_bucket_iam_member" "pubsub_to_bucket_creator" {
  bucket = google_storage_bucket.secondary-spam.name
  member = "serviceAccount:service-${data.google_project.project.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
  role   = "roles/storage.objectCreator"

    depends_on = [
        google_storage_bucket.secondary-spam
    ]
}

# WARNING: This makes the bfilter-service publicly accessible to anyone on the internet.
# Only use this if the service is explicitly designed for unauthenticated public access.
resource "google_cloud_run_v2_service_iam_member" "bfilter_public_invoker" {
  project  = var.project
  location = var.region
  name     = google_cloud_run_v2_service.bfilter-service.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}



#################################################
# SERVICE CONTAINER BUILDS
#################################################

# LLM stub service build module.
module "llm-stub-build" {
  source     = "./llmstub"
  project_id = var.project

  # Ensure Artifact Registry API is enabled before building/pushing images.
  depends_on = [google_project_service.project_apis]
}

# SFilter service build module.
module "sfilter-build" {
  source       = "./sfilter"
  project_id = var.project

  # Ensure Artifact Registry API is enabled before building/pushing images.
  depends_on = [google_project_service.project_apis]

}

# BFilter service build module.
module "bfilter-build" {
  source       = "./bfilter"
  project_id = var.project

  # Ensure Artifact Registry API is enabled before building/pushing images.
  depends_on = [google_project_service.project_apis]
}

# LLM stub service definition.
resource "google_cloud_run_v2_service" "llm-stub-service" {
  name     = "llm-stub-service"
  location = var.region
  deletion_protection = false
  
  labels = local.common_labels
  ingress = "INGRESS_TRAFFIC_INTERNAL_ONLY"

  template {
    labels = local.common_labels
    service_account = google_service_account.llm_stub_sa.email
    
    scaling {
      min_instance_count = 1
      max_instance_count = 10
    }
    
    containers {
      image = module.llm-stub-build.image_name
      
      ports {
        container_port = var.llm_stub_port
      }
    }
    
    vpc_access {
      connector = google_vpc_access_connector.llm-stub-connector.id
      egress    = "ALL_TRAFFIC"
    }
  }
  
  depends_on = [module.llm-stub-build, google_project_service.project_apis, google_service_account.llm_stub_sa, google_vpc_access_connector.llm-stub-connector]
}

# SFilter service definition.
resource "google_cloud_run_v2_service" "sfilter-service" {
  name     = "sfilter-service"
  location = var.region
  deletion_protection = false
  
  labels = local.common_labels
  ingress = "INGRESS_TRAFFIC_INTERNAL_ONLY"

  template {
    labels = local.common_labels
    service_account = google_service_account.sfilter_sa.email
    
    scaling {
      min_instance_count = 1
      max_instance_count = 10
    }
    
    containers {
      image = module.sfilter-build.image_name
      
      ports {
        container_port = var.sfilter_port
      }
      
      env {
        name  = "SECONDARY_MODEL"
        value = "${var.model_mount_path}/${var.model_folder_name}"
      }
      env {
        name  = "SFILTER_CONFIDENCE_THRESHOLD"
        value = var.sfilter_confidence_threshold
      }
      env {
        name  = "ENABLE_REQUEST_LOGGING"
        value = var.enable_request_logging
      }
      env {
        name  = "MAX_MESSAGE_LENGTH"
        value = var.max_message_length
      }

      volume_mounts {
        name       = "model-store-volume"
        mount_path = var.model_mount_path
      }

      resources {
        limits = {
          memory = var.sfilter_memory
          cpu    = "2"
        }
        # cpu_idle = true
        # startup_cpu_boost = true
      }
    }

    volumes {
      name = "model-store-volume"
      gcs {
        bucket    = google_storage_bucket.model-store.name
        read_only = true
      }
    }
    
    vpc_access {
      connector = google_vpc_access_connector.bfilter-connector.id
      egress    = "ALL_TRAFFIC"
    }
  }
  
  depends_on = [module.sfilter-build, google_project_service.project_apis, google_cloud_run_v2_job.model_downloader_job, google_storage_bucket_iam_member.run_service_agent_gcs_mount_access]
}


# BFilter service definition.
resource "google_cloud_run_v2_service" "bfilter-service" {
  name     = "bfilter-service"
  location = var.region
  deletion_protection = false
  
  labels = local.common_labels
  ingress = "INGRESS_TRAFFIC_ALL"  # Make publicly accessible

  template {
    labels = local.common_labels
    service_account = google_service_account.bfilter_sa.email
    
    scaling {
      min_instance_count = 2
      max_instance_count = 10
    }
    
    containers {
      image = module.bfilter-build.image_name
      
      ports {
        container_port = var.bfilter_port
      }
      
      env {
        name  = "LLMSTUB_URL"
        value = google_cloud_run_v2_service.llm-stub-service.uri
      }
      env {
        name  = "SFILTER_URL"
        value = google_cloud_run_v2_service.sfilter-service.uri
      }
      env {
        name  = "PROJECT_ID"
        value = var.project
      }
      env {
        name  = "ENABLE_REQUEST_LOGGING"
        value = var.enable_request_logging
      }
      env {
        name  = "MAX_MESSAGE_LENGTH"
        value = var.max_message_length
      }
    }
    
    vpc_access {
      connector = google_vpc_access_connector.bfilter-connector.id
      egress    = "ALL_TRAFFIC"
    }
  }
  
  depends_on = [module.bfilter-build, google_project_service.project_apis, google_service_account.bfilter_sa, google_vpc_access_connector.bfilter-connector]
}


##############################################
#PUB-SUB CHANNEL
##############################################

# Create topic for secondary filter events.
# This topic will be used to publish events from the bfilter service.
resource "google_pubsub_topic" "secondary_filter_topic" {
  name    = "secondary-filter"
  project = var.project
  # Ensure the Pub/Sub API is enabled before creating the topic.
  depends_on = [google_project_service.project_apis]
}



#ON PUB-SUB CHANNEL SUBSCRIBE TO secondary-filter-topic and write to secondary-spam
resource "google_pubsub_subscription" "secondary_filter_subscription" {
  name    = "secondary-filter-sub"
  topic   = google_pubsub_topic.secondary_filter_topic.name
  project = var.project
  cloud_storage_config {
    bucket = google_storage_bucket.secondary-spam.name
    filename_prefix = "secondary-filter-"
    filename_suffix = ".txt"
  }
  depends_on = [ 
    google_pubsub_topic.secondary_filter_topic, 
    google_storage_bucket.secondary-spam,
    google_storage_bucket_iam_member.pubsub_to_bucket_creator,
    google_storage_bucket_iam_member.pubsub_to_bucket_reader
   ]
}

# Email notification channel (you'll need to replace with actual email)
resource "google_monitoring_notification_channel" "email_alert" {
  display_name = "Email Alert Channel"
  type         = "email"
  
  labels = {
    email_address = "wortcook@gmail.com"  # Replace with actual email
  }
  
  enabled = true
}

# Alert for high latency (over 100ms average)
resource "google_monitoring_alert_policy" "latency_alert" {
  display_name = "High Latency Alert"
  combiner     = "OR"
  
  conditions {
    display_name = "Request Latency > 100ms"
    condition_threshold {
      filter          = "metric.type=\"run.googleapis.com/request_latencies\" AND resource.type=\"cloud_run_revision\""
      duration        = "300s"
      comparison      = "COMPARISON_GT"
      threshold_value = 100  # 100ms in milliseconds
      
      aggregations {
        alignment_period     = "60s"
        per_series_aligner   = "ALIGN_DELTA"
        cross_series_reducer = "REDUCE_MEAN"
        group_by_fields      = ["resource.label.service_name"]
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.email_alert.name]
  
  alert_strategy {
    auto_close = "1800s"
  }
}
