terraform {
  required_providers {
    docker = {
      source = "kreuzwerker/docker"
      version = "~> 3.0.1"
    }
  }
}

resource "docker_image" "sfilter" {
  name = "us-central1-docker.pkg.dev/thomasjones-llm-project-2025/llm-project/sfilter:latest"
  build {
    context = "./sfilter"
    tag = ["sfilter:latest"]
  }
  triggers = {
    dir_sha1 = sha1(join("", [for f in fileset(path.module, "./sfilter/src/**") : filesha1(f)]))
  }
  force_remove = true
  keep_locally = true
}

resource "null_resource" "tag_image" {
  depends_on = [docker_image.sfilter]
  provisioner "local-exec" {
    command = "docker tag sfilter ${docker_image.sfilter.name}"
  }
}

resource "null_resource" "push_image" {
  depends_on = [null_resource.tag_image]
  provisioner "local-exec" {
    command = "docker push ${docker_image.sfilter.name}"
  }
}

output "image_name" {
  description = "The full name of the docker image."
  value       = docker_image.sfilter.name
}

