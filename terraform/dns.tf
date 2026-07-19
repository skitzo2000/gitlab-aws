# Optional real DNS. Everything keys off var.domain:
#   - unset            -> sslip.io wildcard DNS, nothing to manage
#   - set, no zone id  -> you create one A record (see the dns_record output)
#   - set + zone id    -> Terraform manages the A record in Route 53
resource "aws_route53_record" "gitlab" {
  count = var.domain != "" && var.route53_zone_id != "" ? 1 : 0

  zone_id = var.route53_zone_id
  name    = local.gitlab_host
  type    = "A"
  ttl     = 300
  records = [aws_eip.cp.public_ip]
}
