
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 3.20.0"
    }

    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.0.1"
    }
  }
}

data "terraform_remote_state" "eks" {
  backend = "remote"
  config = {
    organization = "example-org-d16576"
    workspaces = {
      name = "eks-cluster"
    }
  }
}

# Retrieve EKS cluster information
provider "aws" {
  region = data.terraform_remote_state.eks.outputs.region
}

data "aws_eks_cluster" "cluster" {
  name = data.terraform_remote_state.eks.outputs.cluster_id
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.cluster.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority.0.data)
  exec {
    api_version = "client.authentication.k8s.io/v1alpha1"
    command     = "aws"
    args = [
      "eks",
      "get-token",
      "--cluster-name",
      data.aws_eks_cluster.cluster.name
    ]
  }
}


resource "kubernetes_deployment" "nginx" {
  metadata {
    name = "scalable-nginx-example"
    labels = {
      App = "ScalableNginxExample"
    }
  }

  spec {
    replicas = 1
    selector {
      match_labels = {
        App = "ScalableNginxExample"
      }
    }
    template {
      metadata {
        labels = {
          App = "ScalableNginxExample"
        }
      }
      spec {
        container {
          image = "199388573085.dkr.ecr.us-east-2.amazonaws.com/video-streaming:latest"
#           image = "nginx:latest"
          name  = "example"
          
         env {
            name = "PORT"
            value = "80"
          }

          port {
            container_port = 80
          }

          resources {
            limits = {
              cpu    = "0.5"
              memory = "512Mi"
            }
            requests = {
              cpu    = "250m"
              memory = "50Mi"
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "nginx" {
  metadata {
    name = "nginx-example"
  }
  spec {
    selector = {
      App = kubernetes_deployment.nginx.spec.0.template.0.metadata[0].labels.App
    }
    port {
      port        = 80
      target_port = 3000
    }

  }
}

output "lb_ip" {
  value = kubernetes_service.nginx.status.0.load_balancer.0.ingress.0.hostname
}


resource "kubernetes_cron_job" "demo" {
  metadata {
    name = "demo"
  }
  spec {
    concurrency_policy            = "Replace"
    failed_jobs_history_limit     = 5
    schedule                      = "1 * * * *"
    starting_deadline_seconds     = 10
    successful_jobs_history_limit = 10
    job_template {
      metadata {}
      spec {
        backoff_limit              = 2
        ttl_seconds_after_finished = 10
        template {
          metadata {}
          spec {
            container {
              name    = "hello"
              image   = "busybox"
              command = ["/bin/sh", "-c", "date; echo Hello from the Kubernetes cluster via cron"]
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_ingress" "main" {
  metadata {
    name = "main-ingress"
    annotations = {
      "alb.ingress.kubernetes.io/scheme" = "internet-facing"
      "kubernetes.io/ingress.class" = "alb"
      "alb.ingress.kubernetes.io/certificate-arn" = "${aws_acm_certificate.cert.arn}"
      "alb.ingress.kubernetes.io/listen-ports" = <<JSON
[
  {"HTTP": 80},
  {"HTTPS": 443}
]
JSON
      "alb.ingress.kubernetes.io/actions.ssl-redirect" = <<JSON
{
  "Type": "redirect",
  "RedirectConfig": {
    "Protocol": "HTTPS",
    "Port": "443",
    "StatusCode": "HTTP_301"
  }
}
JSON
    }
  }

  spec {
    rule {
      host = "53.chapambrose.com"
      http {
        path {
          backend {
            service_name = "ssl-redirect"
            service_port = "use-annotation"
          }
          path = "/*"
        }
        path {
          backend {
            service_name = "nginx"
            service_port = 80
          }
          path = "/*"
        }
      }
    }


  }
}

resource "aws_acm_certificate" "cert" {
  domain_name               = "53.chapambrose.com"
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation-0" {
  name     = aws_acm_certificate.cert.domain_validation_options.0.resource_record_name
  type     = aws_acm_certificate.cert.domain_validation_options.0.resource_record_type
  zone_id  = var.hosted-zone
  records  = [aws_acm_certificate.cert.domain_validation_options.0.resource_record_value]
  ttl      = 60
}

resource "aws_route53_record" "cert_validation-1" {
  name     = aws_acm_certificate.cert.domain_validation_options.1.resource_record_name
  type     = aws_acm_certificate.cert.domain_validation_options.1.resource_record_type
  zone_id  = var.hosted-zone
  records  = [aws_acm_certificate.cert.domain_validation_options.1.resource_record_value]
  ttl      = 60
}

resource "aws_acm_certificate_validation" "cert" {
  certificate_arn         = aws_acm_certificate.cert.arn
  validation_record_fqdns = [
    aws_route53_record.cert_validation-0.fqdn,
    aws_route53_record.cert_validation-1.fqdn,
  ]
}
