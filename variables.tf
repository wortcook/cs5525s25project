
variable "project" {
  description = "The project ID"
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{5,28}[a-z0-9]$", var.project))
    error_message = "Project ID must be 6-30 characters, start with a letter, and contain only lowercase letters, numbers, and hyphens."
  }
}

variable "region" {
  description = "The GCP region for resources."
  type        = string
  default     = "us-central1"
  validation {
    condition = contains([
      "us-central1", "us-east1", "us-west1", "us-west2",
      "europe-west1", "europe-west2", "asia-east1"
    ], var.region)
    error_message = "Region must be one of the supported GCP regions."
  }
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
  default     = "dev"
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be dev, staging, or prod."
  }
}

locals {
  common_labels = {
    project     = var.project
    environment = var.environment
    managed_by  = "terraform"
    owner       = "cs5525-team"
  }
}

variable "zone" {
  description = "The GCP zone for resources."
  default     = "us-central1-c"
}

variable "secondary_model_name" {
  description = "The HuggingFace model name for the secondary classifier."
  type        = string
  default     = "jackhhao/jailbreak-classifier"
}

variable "secondary_model_location" {
  description = "The local path where the secondary model will be downloaded and stored."
  type        = string
  default     = "/app/models/jailbreak-model"
}

variable "llm_stub_port" {
  description = "The container port for the LLM stub service"
  type        = number
  default     = 8081
}

variable "sfilter_port" {
  description = "The container port for the SFilter service"
  type        = number
  default     = 8083
}

variable "bfilter_port" {
  description = "The container port for the BFilter service"
  type        = number
  default     = 8082
}

variable "bfilter_threshold" {
  description = "Confidence threshold for BFilter (0.0-1.0). Messages below this threshold go to SFilter."
  type        = number
  default     = 0.9

  validation {
    condition     = var.bfilter_threshold >= 0.0 && var.bfilter_threshold <= 1.0
    error_message = "BFilter threshold must be between 0.0 and 1.0."
  }
}

variable "sfilter_confidence_threshold" {
  description = "Minimum confidence threshold for SFilter jailbreak detection"
  type        = number
  default     = 0.5

  validation {
    condition     = var.sfilter_confidence_threshold >= 0.0 && var.sfilter_confidence_threshold <= 1.0
    error_message = "SFilter confidence threshold must be between 0.0 and 1.0."
  }
}

variable "enable_request_logging" {
  description = "Enable detailed request logging for debugging"
  type        = bool
  default     = false
}

variable "max_message_length" {
  description = "Maximum allowed message length in characters"
  type        = number
  default     = 10000
}

variable "sfilter_memory" {
  description = "Memory allocation for SFilter service (e.g., '4Gi', '8Gi', '16Gi')"
  type        = string
  default     = "4Gi"

  validation {
    condition     = can(regex("^[0-9]+(Mi|Gi)$", var.sfilter_memory))
    error_message = "Memory must be specified in Mi or Gi format (e.g., '4Gi', '8Gi')."
  }
}