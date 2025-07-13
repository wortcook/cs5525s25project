terraform {
  required_providers {
    docker = {
      source = "kreuzwerker/docker"
      version = "~> 3.0.1"
    }
  }
}

resource "docker_image" "bfilter" {
  name = "us-central1-docker.pkg.dev/thomasjones-llm-project-2025/llm-project/bfilter:latest"
  build {
    context = "./bfilter"
    tag = ["bfilter:latest"]
  }
  triggers = {
    dir_sha1 = sha1(join("", [for f in fileset(path.module, "./bfilter/src/**") : filesha1(f)]))
  }
  force_remove = true
  keep_locally = true
}

resource "null_resource" "tag_image" {
  depends_on = [docker_image.bfilter]
  provisioner "local-exec" {
    command = "docker tag bfilter ${docker_image.bfilter.name}"
  }
}

resource "null_resource" "push_image" {
  depends_on = [null_resource.tag_image]
  provisioner "local-exec" {
    command = "docker push ${docker_image.bfilter.name}"
  }
}

output "image_name" {
  description = "The full name of the docker image."
  value       = docker_image.bfilter.name
}
