terraform {
    required_providers {
    aws = {
      source = "hashicorp/aws"
      version = "4.45.0"
    }
  }
}
provider "aws" {
  region  = var.aws_region
}
locals {
  aws_account = "890213754093"
  ecr_reg   = "${local.aws_account}.dkr.ecr.${var.aws_region}.amazonaws.com"
  ecr_repo  = "ecr"
  image_tag = "latest"

  dkr_img_src_path = "${path.module}/docker-src"
  dkr_img_src_sha256 = sha256(join("", [for f in fileset(".", "${local.dkr_img_src_path}/**") : file(f)]))

  dkr_build_cmd = <<-EOT
        aws ${local.ecr_repo} get-login-password --region ${var.aws_region} |docker login --username AWS --password-stdin ${local.ecr_reg}
        docker build -t ${local.ecr_repo}:${local.image_tag} -f Dockerfile .
        docker tag ${local.ecr_repo}:${local.image_tag} ${local.ecr_reg}
        docker push ${local.ecr_reg}/${local.ecr_repo}:${local.image_tag}
    EOT
}
variable "force_image_rebuild" {
  type    = bool
  default = false
}
resource "null_resource" "build_push_dkr_img" {
  triggers = {
    detect_docker_source_changes = var.force_image_rebuild == true ? timestamp() : local.dkr_img_src_sha256
  }
  provisioner "local-exec" {
    command = local.dkr_build_cmd
  }
}

output "triggered_by" {
  value = null_resource.build_push_dkr_img.triggers
}
resource "aws_ecr_repository" "ecr_repo" {
  name = "ecr"
}
resource "aws_ecs_cluster" "my_cluster" {
  name = "hello-cluster"
}
resource "aws_cloudwatch_log_group" "log_group" {
  name = "fargate-log-group"
}
resource "aws_ecs_task_definition" "app_task" {
  family                   = "hello-world"
  container_definitions    = <<DEFINITION
  [
    {
      "name": "hello-world",
      "image": "${aws_ecr_repository.ecr_repo.repository_url}",
      "essential": true,
      "portMappings": [
        {
          "containerPort": 80,
          "hostPort": 80
        }
      ],
      "memory": 512,
      "cpu": 256,
      "logConfiguration": {
            "logDriver": "awslogs"
            "options": {
            "awslogs-group": "${var.log_group}",
            "awslogs-region": "${var.aws_region}",
            "awslogs-stream-prefix": "ecs"
          }
      }
  }
]
  DEFINITION
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  memory                   = 512
  cpu                      = 256
  execution_role_arn       = "${aws_iam_role.ecsTaskExecutionRole.arn}"
}

resource "aws_iam_role" "ecsTaskExecutionRole" {
  name               = "ecsTaskExecutionRole"
  assume_role_policy = "${data.aws_iam_policy_document.assume_role_policy.json}"
}
data "aws_iam_policy_document" "assume_role_policy" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy_attachment" "ecsTaskExecutionRole_policy" {
  role       = "${aws_iam_role.ecsTaskExecutionRole.name}"
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_vpc" "vpc" {
  cidr_block = var.vpc_cidr
  tags = {
    name = "VPC"
  }
}
resource "aws_subnet" "subnet_1A" {
  vpc_id = aws_vpc.vpc.id
  cidr_block = cidrsubnet(aws_vpc.vpc.cidr_block,8,1 )
  availability_zone = "us-east-1a"
  depends_on = [aws_internet_gateway.igw-t]
  tags = {
    name = "Subnet-1A"
  }
}
resource "aws_subnet" "subnet_1B" {
  vpc_id                  = aws_vpc.vpc.id
  cidr_block              = cidrsubnet(aws_vpc.vpc.cidr_block, 8, 2)
  map_public_ip_on_launch = true
  availability_zone       = "us-east-1b"
  depends_on = [aws_internet_gateway.igw-t]
  tags = {
    name = "Subnet-1B"
  }
}

resource "aws_route_table" "rt"{
  vpc_id = aws_vpc.vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw-t.id
  }
  tags = {
    name = "RT"
  }
}
resource "aws_route_table_association" "RT_to_Subnet1A" {
  subnet_id      = aws_subnet.subnet_1A.id
  route_table_id = aws_route_table.rt.id
}

resource "aws_route_table_association" "RT_to_Subnet1B" {
  subnet_id      = aws_subnet.subnet_1B.id
  route_table_id = aws_route_table.rt.id
}


resource "aws_internet_gateway" "igw-t" {
  vpc_id = aws_vpc.vpc.id
  tags = {
    name = "IGW"
  }
}

resource "aws_security_group" "load_balancer_security_group" {
  name = "LB-SG"
  vpc_id = aws_vpc.vpc.id
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_alb" "application_load_balancer" {
  name               = "alb"
  load_balancer_type = "application"
  subnets = [
    "${aws_subnet.subnet_1A.id}",
    "${aws_subnet.subnet_1B.id}"
  ]
  security_groups = ["${aws_security_group.load_balancer_security_group.id}"]
}
resource "aws_lb_target_group" "target_group" {
  name        = "target-group"
  port        = 80
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = "${aws_vpc.vpc.id}"
}

resource "aws_lb_listener" "listener" {
  load_balancer_arn = "${aws_alb.application_load_balancer.arn}"
  port              = "80"
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = "${aws_lb_target_group.target_group.arn}"
  }
}
resource "aws_security_group" "service_security_group" {
  name = "SC-SG"
  vpc_id = aws_vpc.vpc.id
  ingress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    security_groups = ["${aws_security_group.load_balancer_security_group.id}"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
resource "aws_ecs_service" "app_service" {
  name            = "app-first-service"
  cluster         = "${aws_ecs_cluster.my_cluster.id}"
  task_definition = "${aws_ecs_task_definition.app_task.arn}"
  launch_type     = "FARGATE"
  desired_count   = 3
  load_balancer {
    target_group_arn = "${aws_lb_target_group.target_group.arn}"
    container_name   = "${aws_ecs_task_definition.app_task.family}"
    container_port   = 80
  }
  network_configuration {
    subnets          = ["${aws_subnet.subnet_1A.id}", "${aws_subnet.subnet_1B.id}"]
    assign_public_ip = true
    security_groups  = ["${aws_security_group.service_security_group.id}"]
  }
}


output "app_url" {
  value = aws_alb.application_load_balancer.dns_name
}



