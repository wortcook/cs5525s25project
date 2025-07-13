terraform {
  required_providers {
    time = {
      source  = "hashicorp/time"
      version = "~> 0.9"
    }
  }
}

provider "google" {
  project = var.project
  region  = var.region
  zone    = var.zone
  #  credentials = file("thomasjones-llm-project-2025-7725b32a4ec0.json")
}

data "google_project" "project" {
}

resource "google_project_service" "project_apis" {
  project  = var.project
  for_each = toset([
    "iam.googleapis.com",
    "run.googleapis.com",
    "compute.googleapis.com",
    "storage.googleapis.com",
    "artifactregistry.googleapis.com",
    "vpcaccess.googleapis.com",
  ])
  service                    = each.key
  disable_on_destroy         = false
  disable_dependent_services = false

  # No retry logic needed directly in this resource
}

resource "google_compute_network" "llm-vpc" {
  name                    = "llm-vpc"
  auto_create_subnetworks = false
  mtu                     = 1460

  # Ensure the Compute API is enabled before creating the network.
  # depends_on = [google_project_service.project_apis, null_resource.compute_api_retry]
  depends_on = [google_project_service.project_apis]
}

resource "google_compute_subnetwork" "llm-vpc-filter-subnet" {
  name          = "llm-vpc-filter-subnet"
  ip_cidr_range = "10.0.1.0/28" # Increased subnet size
  region        = var.region
  private_ip_google_access = true
  network       = google_compute_network.llm-vpc.id

  # The bfilter-service implicitly depends on this subnet. The service
  # in turn depends on the time_sleep resource, which depends on this subnet,
  # creating the correct destroy order to prevent race conditions.
}

resource "time_sleep" "wait_for_ip_release" {
  # This resource introduces a delay between the destruction of the Cloud Run
  # service and the subnetwork it uses. This prevents a race condition where
  # Terraform tries to delete the subnetwork while its IP is still reserved
  # by the Serverless VPC Access connector.
  destroy_duration = "60s"

  depends_on = [google_compute_subnetwork.llm-vpc-filter-subnet]
}

resource "google_compute_subnetwork" "llmstub-subnet" {
  name          = "llmstub-subnet"
  ip_cidr_range = "10.0.2.0/28" # Choose an appropriate IP range
  region        = "us-central1"  # Match your project's region
  network       = google_compute_network.llm-vpc.id

  # Enable Private Google Access (optional, but recommended)
  private_ip_google_access = true

  depends_on = [google_project_service.project_apis, time_sleep.wait_for_ip_release]
}

resource "random_id" "connector_suffix" {
  byte_length = 4  # Generates 16 hex characters
}

resource "google_vpc_access_connector" "bfilter-connector" {
  name          = "bfilter-${random_id.connector_suffix.dec}"
  region        = var.region
  min_instances = 2
  max_instances = 8
  subnet {
    name = google_compute_subnetwork.llm-vpc-filter-subnet.name
  }
  depends_on = [google_project_service.project_apis, time_sleep.wait_for_ip_release]
}

resource "google_compute_firewall" "default" {
  name        = "allow-http-https-ingress"
  network     = google_compute_network.llm-vpc.name # Reference the custom VPC network
  priority    = 1000 # Lower number means higher priority
  direction   = "INGRESS"
  source_ranges = ["0.0.0.0/0"] # Allow HTTP/HTTPS from any source
  allow {
    protocol = "tcp"
    ports    = ["80", "443"] # Allow HTTP and HTTPS
  }
}

resource "google_compute_firewall" "allow-internal-llmstub" {
  name    = "allow-internal-llmstub"
  network = google_compute_network.llm-vpc.name

  allow {
    protocol = "tcp"
    ports    = ["8082"] # Assuming llmstub listens on port 8082, adjust as needed
  }

  source_ranges = ["10.0.0.0/28", "10.0.2.0/28"] # Allow traffic from main subnet and llmstub-subnet
  target_tags   = ["http-server"] # Or any relevant target tag for your service
}

###############
# STORAGE
###############
resource "google_storage_bucket" "model-store" {
  name     = "model-store-${var.project}"
  location = var.region

  # When deleting the bucket, this will also delete all objects in it.
  force_destroy = true

  uniform_bucket_level_access = true

  # Ensure the Storage API is enabled before creating the bucket.
  depends_on = [google_project_service.project_apis]
}

resource "google_storage_bucket" "secondary-spam" {
  name     = "secondary-spam-${var.project}"
  location = var.region

  # When deleting the bucket, this will also delete all objects in it.
  force_destroy = true

  uniform_bucket_level_access = true

  # Ensure the Storage API is enabled before creating the bucket.
  depends_on = [google_project_service.project_apis]
}


###############
# MODEL DOWNLOADER
###############
module "model-downloader-build" {
  source     = "./model-downloader"
  project_id = var.project

  # Ensure Artifact Registry API is enabled before building/pushing images.
  depends_on = [google_project_service.project_apis] # Ensure VPC Access API is also enabled
}

resource "google_service_account" "model_downloader_sa" {
  account_id   = "model-downloader-sa"
  display_name = "Model Downloader Service Account"
  project      = var.project

  # Ensure the IAM API is enabled before creating the service account.
  depends_on = [google_project_service.project_apis]
}

resource "google_storage_bucket_iam_member" "model_downloader_gcs_writer" {
  bucket = google_storage_bucket.model-store.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.model_downloader_sa.email}"
}

resource "null_resource" "model-download" {
  triggers = {
    # Re-run the job if the job definition, model name, or container image changes.
    job_id     = google_cloud_run_v2_job.model_downloader_job.id
    model_name = var.secondary_model_name
    image_id   = module.model-downloader-build.image_id
  }

  provisioner "local-exec" {
    # This command executes the Cloud Run Job.
    command = "gcloud run jobs execute ${google_cloud_run_v2_job.model_downloader_job.name} --region ${google_cloud_run_v2_job.model_downloader_job.location} --wait --project ${var.project}"
  }

  depends_on = [google_cloud_run_v2_job.model_downloader_job]
}

###############
# SERVICE ACCOUNTS & PERMISSIONS
###############

resource "google_service_account" "llm_stub_sa" {
  account_id   = "llm-stub-sa"
  display_name = "LLM Stub Service Account"
  project      = var.project
  depends_on   = [google_project_service.project_apis]
}

resource "google_service_account" "sfilter_sa" {
  account_id   = "sfilter-sa"
  display_name = "SFilter Service Account"
  project      = var.project
  depends_on   = [google_project_service.project_apis]
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

resource "google_service_account" "bfilter_sa" {
  account_id   = "bfilter-sa"
  display_name = "BFilter Service Account"
  project      = var.project
  depends_on   = [google_project_service.project_apis]
}

# Grant bfilter service account permission to invoke llm-stub service.
resource "google_cloud_run_v2_service_iam_member" "bfilter_invokes_llmstub" {
  project  = google_cloud_run_v2_service.llm-stub-service.project
  location = google_cloud_run_v2_service.llm-stub-service.location
  name     = google_cloud_run_v2_service.llm-stub-service.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.bfilter_sa.email}"
}

# Grant bfilter service account permission to invoke sfilter service.
resource "google_cloud_run_v2_service_iam_member" "bfilter_invokes_sfilter" {
  project  = google_cloud_run_v2_service.sfilter-service.project
  location = google_cloud_run_v2_service.sfilter-service.location
  name     = google_cloud_run_v2_service.sfilter-service.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.bfilter_sa.email}"
}

###############
# SERVICE WORKERS
###############
module "llm-stub-build" {
  source     = "./llmstub"
  project_id = var.project

  # Ensure Artifact Registry API is enabled before building/pushing images.
  depends_on = [google_project_service.project_apis]
}

module "sfilter-build" {
  source       = "./sfilter"

  # Ensure Artifact Registry API is enabled before building/pushing images.
  depends_on = [google_project_service.project_apis]

}

module "bfilter-build" {
  source       = "./bfilter"

  # Ensure Artifact Registry API is enabled before building/pushing images.
  depends_on = [google_project_service.project_apis]
}

resource "google_vpc_access_connector" "llm-stub-connector" {
  name          = "llm-stub-${random_id.connector_suffix.dec}"
  region        = "us-central1"
  min_instances = 2
  max_instances = 8
  subnet {
    name = google_compute_subnetwork.llmstub-subnet.name
  }
}

resource "google_cloud_run_v2_service" "llm-stub-service" {
  name     = "llm-stub-service"
  location = var.region
  deletion_protection = false

  ingress = "INGRESS_TRAFFIC_INTERNAL_ONLY"
 
  template {
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

  # Ensure the Run API is enabled and the image is built.
  depends_on = [module.llm-stub-build, google_project_service.project_apis, google_service_account.llm_stub_sa, google_vpc_access_connector.llm-stub-connector]
}

resource "google_cloud_run_v2_service" "sfilter-service" {
  name     = "sfilter-service"
  location = var.region
  project  = var.project
  deletion_protection = false

  template {
    scaling {
      min_instance_count = 1  # Keep at least 1 instance warm
      max_instance_count = 10
    }
    
    containers {
      image = module.sfilter-build.image_name
      ports {
        container_port = var.sfilter_port
      }
      
      # Allocate more CPU for faster model loading
      resources {
        limits = {
          memory = var.sfilter_memory
          cpu    = "2"
        }
        cpu_idle = true  # Keep CPU allocated when idle
        startup_cpu_boost = true  # Faster container startup
      }
      
      env {
        name  = "SECONDARY_MODEL"
        value = "/mnt/models/${var.secondary_model_name}"
      }
      env{
        name = "SFILTER_CONFIDENCE_THRESHOLD"
        value = var.sfilter_confidence_threshold
      }
      env{
        name = "ENABLE_REQUEST_LOGGING"
        value = var.enable_request_logging
      }
      env{
        name = "MAX_MESSAGE_LENGTH"
        value = var.max_message_length
      }
      
      # Mount the model from GCS for faster loading
      volume_mounts {
        name       = "model-storage"
        mount_path = "/mnt/models"
      }
    }
    
    # Add volume for model mounting
    volumes {
      name = "model-storage"
      gcs {
        bucket    = google_storage_bucket.model-store.name
        read_only = true
      }
    }
    
    service_account = google_service_account.sfilter_sa.email
    vpc_access {
      connector = google_vpc_access_connector.bfilter-connector.id
      egress    = "ALL_TRAFFIC"
    }
    
    # Faster startup timeout
    timeout = "60s"
  }

  depends_on = [module.sfilter-build, google_project_service.project_apis, google_cloud_run_v2_job.model_downloader_job, google_storage_bucket_iam_member.run_service_agent_gcs_mount_access]
}

resource "google_cloud_run_v2_service" "bfilter-service" {
  name     = "bfilter-service"
  location = var.region
  deletion_protection = false

  template {
    service_account = google_service_account.bfilter_sa.email
    scaling {
      min_instance_count = 1
      max_instance_count = 10
    }
    vpc_access{
      # network_interfaces {
      #   network = google_compute_network.llm-vpc.id
      #   subnetwork = google_compute_subnetwork.llm-vpc-filter-subnet.id
      # }
      connector = google_vpc_access_connector.bfilter-connector.id
      egress = "ALL_TRAFFIC"
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
      env{
        name = "SFILTER_URL"
        value = google_cloud_run_v2_service.sfilter-service.uri
      }
      env{
        name = "PROJECT_ID"
        value = var.project
      }
      env{
        name = "BFILTER_THRESHOLD"
        value = var.bfilter_threshold
      }
      env{
        name = "ENABLE_REQUEST_LOGGING"
        value = var.enable_request_logging
      }
      env{
        name = "MAX_MESSAGE_LENGTH"
        value = var.max_message_length
      }
    }
  }

  depends_on = [
    module.bfilter-build,
    google_cloud_run_v2_service.llm-stub-service,
    google_cloud_run_v2_service.sfilter-service,
    google_project_service.project_apis,
    google_service_account.bfilter_sa,
    google_vpc_access_connector.bfilter-connector,
  ]
}

# WARNING: This makes the bfilter-service publicly accessible to anyone on the internet.
# Only use this if the service is explicitly designed for unauthenticated public access.
resource "google_cloud_run_v2_service_iam_member" "bfilter_public_invoker" {
  project  = google_cloud_run_v2_service.bfilter-service.project
  location = google_cloud_run_v2_service.bfilter-service.location
  name     = google_cloud_run_v2_service.bfilter-service.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

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
          name  = "HF_MODEL_NAME"
          value = var.secondary_model_name
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

#PUB-SUB CHANNEL
resource "google_pubsub_topic" "secondary_filter_topic" {
  name    = "secondary-filter"
  project = var.project
  # Ensure the Pub/Sub API is enabled before creating the topic.
  depends_on = [google_project_service.project_apis]
}

# Example subscription (optional):
# resource "google_pubsub_subscription" "secondary_filter_subscription" {
#   name  = "secondary-filter-sub"
#   topic = google_pubsub_topic.secondary_filter_topic.name
# }

resource "google_pubsub_topic_iam_member" "bfilter_publishes_to_secondary_filter" {
  project = var.project
  topic   = google_pubsub_topic.secondary_filter_topic.name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${google_service_account.bfilter_sa.email}"

  depends_on = [google_pubsub_topic.secondary_filter_topic, google_service_account.bfilter_sa]
}


resource "google_storage_bucket_iam_member" "pubsub_to_bucket_reader" {
  bucket = google_storage_bucket.secondary-spam.name
  member = "serviceAccount:service-${data.google_project.project.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
  role   = "roles/storage.legacyBucketReader"

    depends_on = [
        google_storage_bucket.secondary-spam
    ]
}

resource "google_storage_bucket_iam_member" "pubsub_to_bucket_creator" {
  bucket = google_storage_bucket.secondary-spam.name
  member = "serviceAccount:service-${data.google_project.project.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
  role   = "roles/storage.objectCreator"

    depends_on = [
        google_storage_bucket.secondary-spam
    ]
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

# Cloud Monitoring - Health Check Uptime Checks
resource "google_monitoring_uptime_check_config" "bfilter_health_check" {
  display_name = "BFilter Health Check"
  timeout      = "10s"
  period       = "60s"

  http_check {
    use_ssl         = true
    path            = "/health"
    port            = "443"
    request_method  = "GET"
  }

  monitored_resource {
    type = "uptime_url"
    labels = {
      project_id = var.project
      host       = google_cloud_run_v2_service.bfilter-service.uri
    }
  }

  content_matchers {
    content = "healthy"
    matcher = "CONTAINS_STRING"
  }

  depends_on = [google_cloud_run_v2_service.bfilter-service]
}

resource "google_monitoring_uptime_check_config" "sfilter_health_check" {
  display_name = "SFilter Health Check"
  timeout      = "10s"
  period       = "60s"

  http_check {
    use_ssl         = true
    path            = "/health"
    port            = "443"
    request_method  = "GET"
  }

  monitored_resource {
    type = "uptime_url"
    labels = {
      project_id = var.project
      host       = google_cloud_run_v2_service.sfilter-service.uri
    }
  }

  content_matchers {
    content = "healthy"
    matcher = "CONTAINS_STRING"
  }

  depends_on = [google_cloud_run_v2_service.sfilter-service]
}

resource "google_monitoring_uptime_check_config" "llmstub_health_check" {
  display_name = "LLMStub Health Check"
  timeout      = "10s"
  period       = "60s"

  http_check {
    use_ssl         = true
    path            = "/health"
    port            = "443"
    request_method  = "GET"
  }

  monitored_resource {
    type = "uptime_url"
    labels = {
      project_id = var.project
      host       = google_cloud_run_v2_service.llm-stub-service.uri
    }
  }

  content_matchers {
    content = "healthy"
    matcher = "CONTAINS_STRING"
  }

  depends_on = [google_cloud_run_v2_service.llm-stub-service]
}

# Alert Policy for Service Health
resource "google_monitoring_alert_policy" "service_health_alert" {
  display_name = "LLM Infrastructure Service Health Alert"
  combiner     = "OR"
  
  conditions {
    display_name = "BFilter Service Down"
    condition_threshold {
      filter          = "metric.type=\"monitoring.googleapis.com/uptime_check/check_passed\" AND resource.type=\"uptime_url\""
      duration        = "300s"
      comparison      = "COMPARISON_EQUAL"
      threshold_value = 0
      
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_NEXT_OLDER"
      }
    }
  }

  conditions {
    display_name = "SFilter Service Down"
    condition_threshold {
      filter          = "metric.type=\"monitoring.googleapis.com/uptime_check/check_passed\" AND resource.type=\"uptime_url\""
      duration        = "300s"
      comparison      = "COMPARISON_EQUAL"
      threshold_value = 0
      
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_NEXT_OLDER"
      }
    }
  }

  conditions {
    display_name = "LLMStub Service Down"
    condition_threshold {
      filter          = "metric.type=\"monitoring.googleapis.com/uptime_check/check_passed\" AND resource.type=\"uptime_url\""
      duration        = "300s"
      comparison      = "COMPARISON_EQUAL"
      threshold_value = 0
      
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_NEXT_OLDER"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.email_alert.name]

  alert_strategy {
    auto_close = "1800s"  # Auto-close after 30 minutes
  }

  depends_on = [
    google_monitoring_uptime_check_config.bfilter_health_check,
    google_monitoring_uptime_check_config.sfilter_health_check,
    google_monitoring_uptime_check_config.llmstub_health_check
  ]
}

# Email notification channel (you'll need to replace with actual email)
resource "google_monitoring_notification_channel" "email_alert" {
  display_name = "Email Alert Channel"
  type         = "email"
  
  labels = {
    email_address = "admin@yourdomain.com"  # Replace with actual email
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
