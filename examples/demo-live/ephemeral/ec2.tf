# Elastic Compute Cloud capacity for the runner. Fargate does not permit the
# user namespaces that rootless BuildKit needs, so the runner runs on a small
# instance whose kernel does permit them. The application service stays on
# Fargate. The instance lives only while the environment is up.

data "aws_ssm_parameter" "ecs_ami" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2023/recommended/image_id"
}

resource "aws_iam_role" "ecs_instance" {
  name = "${local.prefix}-ecs-instance"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}
resource "aws_iam_role_policy_attachment" "ecs_instance" {
  role       = aws_iam_role.ecs_instance.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}
resource "aws_iam_role_policy_attachment" "ecs_instance_ssm" {
  role       = aws_iam_role.ecs_instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
resource "aws_iam_instance_profile" "ecs_instance" {
  name = "${local.prefix}-ecs-instance"
  role = aws_iam_role.ecs_instance.name
}

# Host security group: no inbound, egress only (reaches GitHub.com and AWS via NAT).
resource "aws_security_group" "host" {
  name_prefix = "${local.prefix}-host-"
  vpc_id      = aws_vpc.this.id
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  lifecycle { create_before_destroy = true }
}

resource "aws_launch_template" "runner_host" {
  name_prefix   = "${local.prefix}-runner-host-"
  image_id      = data.aws_ssm_parameter.ecs_ami.value
  instance_type = var.runner_instance_type

  iam_instance_profile { arn = aws_iam_instance_profile.ecs_instance.arn }
  vpc_security_group_ids = [aws_security_group.host.id]

  user_data = base64encode(<<-EOT
    #!/bin/bash
    echo "ECS_CLUSTER=${aws_ecs_cluster.this.name}" >> /etc/ecs/ecs.config
    echo "ECS_ENABLE_TASK_ENI=true" >> /etc/ecs/ecs.config
    # Always pull the runner image so a rebuilt :latest is never served stale.
    echo "ECS_IMAGE_PULL_BEHAVIOR=always" >> /etc/ecs/ecs.config
    # Permit unprivileged user namespaces so rootless BuildKit can start.
    sysctl -w user.max_user_namespaces=15000 || true
    echo 'user.max_user_namespaces=15000' > /etc/sysctl.d/99-userns.conf
  EOT
  )

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${local.prefix}-runner-host" }
  }
}

resource "aws_autoscaling_group" "runner_host" {
  name_prefix         = "${local.prefix}-runner-host-"
  min_size            = 1
  max_size            = 1
  desired_capacity    = 1
  vpc_zone_identifier = aws_subnet.private[*].id
  health_check_type   = "EC2"

  launch_template {
    id      = aws_launch_template.runner_host.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "${local.prefix}-runner-host"
    propagate_at_launch = true
  }
  tag {
    key                 = "AmazonECSManaged"
    value               = "true"
    propagate_at_launch = true
  }
}
