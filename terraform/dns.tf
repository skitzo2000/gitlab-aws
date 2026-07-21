# Optional real DNS. Everything keys off var.domain:
#   - unset                       -> sslip.io wildcard DNS, nothing to manage
#   - set, no zone id             -> you create one A record (dns_record output)
#   - set + route53_zone_id       -> Terraform manages the A record in Route 53
#   - set + cloudflare_zone_id    -> Terraform manages it in Cloudflare (DNS-only)
resource "aws_route53_record" "gitlab" {
  count = var.domain != "" && var.route53_zone_id != "" ? 1 : 0

  zone_id = var.route53_zone_id
  name    = local.gitlab_host
  type    = "A"
  ttl     = 300
  records = [aws_eip.cp.public_ip]
}

# proxied is deliberately hard-false, not a variable: Cloudflare's proxy
# would break Let's Encrypt issuance and can't carry 5050/2222 at all.
resource "cloudflare_dns_record" "gitlab" {
  count = var.domain != "" && var.cloudflare_zone_id != "" ? 1 : 0

  zone_id = var.cloudflare_zone_id
  name    = local.gitlab_host
  type    = "A"
  content = aws_eip.cp.public_ip
  ttl     = 300
  proxied = false
}
