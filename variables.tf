variable "project" {
  description = "The project ID"
  default     = "thomasjones-llm-project-2025"
}

variable "region" {
  description = "The GCP region for resources."
  default     = "us-central1"
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
  description = "The path within the GCS bucket where the secondary model is stored."
  type        = string
  default     = "/storage/models/jailbreak-classifier"
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