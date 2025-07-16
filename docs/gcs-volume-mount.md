# GCS Volume Mount Implementation for Cloud Run v2

## Overview
This document describes the implementation of GCS volume mounting for the SFilter service in the LLM Security Infrastructure project.

## Implementation Details

### Architecture Change
**Replaced module-based approach with explicit service blocks** to simplify configuration and resolve syntax issues with GCS volume mounting.

### Terraform Configuration
The GCS volume mount is implemented using explicit `google_cloud_run_v2_service` resources in the main.tf file.

### SFilter Service with GCS Volume Mount

#### Key Components

**1. Volume Mount Configuration**
```terraform
volume_mounts {
  name       = "model-store-volume"
  mount_path = var.model_mount_path
}
```

**2. GCS Volume Block**
```terraform
volumes {
  name = "model-store-volume"
  gcs {
    bucket    = google_storage_bucket.model-store.name
    read_only = true
  }
}
```

**3. Environment Variable**
```terraform
env {
  name  = "SECONDARY_MODEL"
  value = "${var.model_mount_path}/${var.model_folder_name}"
}
```

### Complete SFilter Service Configuration
```terraform
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
        cpu_idle = true
        startup_cpu_boost = true
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
```

### Variables Configuration
In `variables.tf`:
- `model_mount_path` (default: "/storage/models") - Path where GCS bucket is mounted
- `model_folder_name` (default: "jailbreak-model") - Folder name within the bucket

### Benefits of Explicit Services vs Module Approach
1. **Simplicity**: Direct configuration without module abstraction
2. **Clarity**: All service configuration visible in main.tf
3. **Compatibility**: Direct use of Cloud Run v2 syntax without translation layers
4. **Maintainability**: Fewer files and indirection levels
5. **Debugging**: Easier to troubleshoot configuration issues

### Service Configuration Summary
- **BFilter Service**: Public-facing (INGRESS_TRAFFIC_ALL), no GCS volumes
- **SFilter Service**: Internal-only with GCS model volume mount
- **LLM Stub Service**: Internal-only, simple configuration

### Updated References
All service references updated from module outputs to direct resource attributes:
- `module.sfilter_service.service_url` → `google_cloud_run_v2_service.sfilter-service.uri`
- `module.bfilter_service.service_name` → `google_cloud_run_v2_service.bfilter-service.name`
- `module.llm_stub_service.service_url` → `google_cloud_run_v2_service.llm-stub-service.uri`

### Technical Notes
- Uses Cloud Run v2 native GCS volume mounting
- Volume is mounted as read-only for security
- Service account requires Storage Object Viewer permissions on the bucket
- Model accessed at: `/storage/models/jailbreak-model/`

## Related Files
- `main.tf` - All service configurations (explicit blocks)
- `outputs.tf` - Updated service URL outputs
- `variables.tf` - Variable definitions
- `sfilter/Dockerfile` - Container configuration
