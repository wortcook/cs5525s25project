terraform {
  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.0.1"
    }
  }
}

variable "project_id" {
  description = "The GCP project ID."
  type        = string
}

resource "docker_image" "model_downloader" {
  name = "us-central1-docker.pkg.dev/${var.project_id}/llm-project/model-downloader:latest"
  build {
    context  = path.module
    tag      = ["model-downloader:latest"]
    platform = "linux/amd64"
  }
  triggers = {
    dir_sha1 = sha1(join("", [for f in fileset(path.module, "**/*") : filesha1("${path.module}/${f}")]))
  }
  force_remove = true
  keep_locally = true # To allow tagging and pushing via local-exec
}

resource "null_resource" "tag_image" {
  depends_on = [docker_image.model_downloader]
  provisioner "local-exec" {
    command = "docker tag model-downloader:latest ${docker_image.model_downloader.name}"
  }
}

resource "null_resource" "push_image" {
  depends_on = [null_resource.tag_image]
  provisioner "local-exec" {
    command = "docker push ${docker_image.model_downloader.name}"
  }
}

output "image_name" {
  description = "The full name of the docker image."
  value       = docker_image.model_downloader.name
}

output "image_id" {
  description = "The ID of the docker image."
  value       = docker_image.model_downloader.id
}